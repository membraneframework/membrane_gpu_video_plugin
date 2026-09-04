use crate::encoder::{EncoderRateControl, EncoderTune};
use crate::{EncodedFrame, Resource};
use gpu_video::parameters::{
    AnyEncoderParameters, Rational, TranscoderOutputParameters, TranscoderParameters,
};
use gpu_video::{EncodedInputChunk, EncodedOutputChunk, Transcoder};
use rustler::{Binary, Env, Error, NifStruct, NifUnitEnum, OwnedBinary, ResourceArc};
use std::sync::Mutex;

pub struct SendTranscoder(Transcoder);

// SAFETY: `Transcoder` is not auto-Send only because gpu-video's internal
// `dyn Encoder` trait object lacks a `Send` bound; the concrete encoder types
// behind it are the same as in `BytesEncoderH264`, which is Send.
unsafe impl Send for SendTranscoder {}

pub struct TranscoderResource {
    pub transcoder_mutex: Mutex<Option<SendTranscoder>>,
}

#[derive(NifStruct, Clone, Copy)]
#[module = "Membrane.GPUVideo.Transcoder.OutputSpec"]
pub struct OutputSpec {
    pub width: u32,
    pub height: u32,
    pub tune: EncoderTune,
    pub rate_control: EncoderRateControl,
    pub scaling_algorithm: ScalingAlgorithm,
}

#[derive(NifUnitEnum, Clone, Copy)]
pub enum ScalingAlgorithm {
    NearestNeighbor,
    Lanczos3,
    Bilinear,
}

impl From<ScalingAlgorithm> for gpu_video::parameters::ScalingAlgorithm {
    fn from(algorithm: ScalingAlgorithm) -> Self {
        match algorithm {
            ScalingAlgorithm::NearestNeighbor => Self::NearestNeighbor,
            ScalingAlgorithm::Lanczos3 => Self::Lanczos3,
            ScalingAlgorithm::Bilinear => Self::Bilinear,
        }
    }
}

pub fn new(
    _env: Env,
    resource: ResourceArc<Resource>,
    output_specs: Vec<OutputSpec>,
    approx_framerate: (u32, u32),
) -> Result<ResourceArc<Resource>, Error> {
    let device_resource = &resource
        .device()
        .ok_or_else(|| Error::RaiseTerm(Box::new("Resource is not a device")))?
        .device;
    let output_parameters = output_specs
        .iter()
        .map(|spec| {
            let non_zero_width = std::num::NonZero::new(spec.width).ok_or(Error::RaiseTerm(
                Box::new("Improper width: width must be non-zero"),
            ))?;
            let non_zero_height = std::num::NonZero::new(spec.height).ok_or(Error::RaiseTerm(
                Box::new("Improper height: height must be non-zero"),
            ))?;

            let encoder_parameters = match spec.tune {
                EncoderTune::LowLatency => device_resource
                    .encoder_output_parameters_h264_low_latency(spec.rate_control.into()),
                EncoderTune::HighQuality => device_resource
                    .encoder_output_parameters_h264_high_quality(spec.rate_control.into()),
            }
            .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

            Ok(TranscoderOutputParameters {
                encoder_parameters: AnyEncoderParameters::H264(encoder_parameters),
                output_width: non_zero_width,
                output_height: non_zero_height,
                scaling_algorithm: spec.scaling_algorithm.into(),
            })
        })
        .collect::<Result<Vec<_>, _>>()?;

    let transcoder_parameters = TranscoderParameters {
        input_framerate: Rational {
            numerator: approx_framerate.0,
            denominator: std::num::NonZero::new(approx_framerate.1).ok_or(Error::RaiseTerm(
                Box::new(
                    "Improper approx_framerate denominator: approx_framerate denominator must be non-zero",
                ),
            ))?,
        },
        output_parameters,
    };

    let transcoder = device_resource
        .create_transcoder(transcoder_parameters)
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;
    let transcoder_mutex = Mutex::new(Some(SendTranscoder(transcoder)));
    let transcoder = TranscoderResource { transcoder_mutex };

    let resource = ResourceArc::new(Resource::Transcoder(transcoder));
    Ok(resource)
}

pub fn transcode<'a>(
    env: Env<'a>,
    resource: ResourceArc<Resource>,
    bytes: Binary,
    pts_ns: Option<u64>,
) -> Result<Vec<Vec<EncodedFrame<'a>>>, Error> {
    let transcoder = resource
        .transcoder()
        .ok_or_else(|| Error::RaiseTerm(Box::new("Resource is not a transcoder")))?;
    let mut guard = transcoder
        .transcoder_mutex
        .lock()
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;
    let transcoder = &mut guard
        .as_mut()
        .ok_or(Error::RaiseTerm(Box::new(
            "Transcoder resource is not initialized",
        )))?
        .0;

    let encoded_input_chunk = EncodedInputChunk {
        data: bytes.as_slice(),
        pts: pts_ns,
    };

    let encoded_output_chunks = transcoder
        .transcode(encoded_input_chunk)
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    process_outputs_chunks(env, encoded_output_chunks)
}

pub fn flush<'a>(
    env: Env<'a>,
    resource: ResourceArc<Resource>,
) -> Result<Vec<Vec<EncodedFrame<'a>>>, Error> {
    let transcoder = resource
        .transcoder()
        .ok_or_else(|| Error::RaiseTerm(Box::new("Resource is not a transcoder")))?;
    let mut guard = transcoder
        .transcoder_mutex
        .lock()
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;
    let transcoder = &mut guard
        .as_mut()
        .ok_or(Error::RaiseTerm(Box::new(
            "Transcoder resource is not initialized",
        )))?
        .0;

    let encoded_output_chunks = transcoder
        .flush()
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    process_outputs_chunks(env, encoded_output_chunks)
}

fn process_outputs_chunks<'a>(
    env: Env<'a>,
    encoded_outputs_chunks: Vec<Vec<EncodedOutputChunk<Vec<u8>>>>,
) -> Result<Vec<Vec<EncodedFrame<'a>>>, Error> {
    encoded_outputs_chunks
        .into_iter()
        .map(|chunks| {
            chunks
                .into_iter()
                .map(|chunk| {
                    Ok(EncodedFrame {
                        pts_ns: chunk.pts,
                        payload: to_binary(env, &chunk.data)?,
                    })
                })
                .collect()
        })
        .collect()
}

fn to_binary<'a>(env: Env<'a>, data: &[u8]) -> Result<Binary<'a>, Error> {
    let mut binary = OwnedBinary::new(data.len())
        .ok_or(Error::RaiseTerm(Box::new("Couldn't create OwnedBinary")))?;
    binary.as_mut_slice().copy_from_slice(data);
    Ok(binary.release(env))
}
