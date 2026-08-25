use crate::encoder::{EncoderRateControl, EncoderTune};
use crate::{EncodedFrame, Resource};
use rustler::{Atom, Binary, Env, Error, NifStruct, OwnedBinary, ResourceArc};
use std::sync::Mutex;
use gpu_video::parameters::{
    AnyEncoderParameters, Rational, ScalingAlgorithm, TranscoderOutputParameters,
    TranscoderParameters,
};
use gpu_video::{EncodedInputChunk, EncodedOutputChunk, Transcoder};

rustler::atoms! {
  unknown_scaling_algorithm
}

pub struct TranscoderResource {
    pub transcoder_mutex: Mutex<Option<Transcoder>>,
}

#[derive(NifStruct, Clone, Copy)]
#[module = "Membrane.GPUVideo.Transcoder.OutputSpec"]
pub struct OutputSpec {
    pub width: u32,
    pub height: u32,
    pub tune: EncoderTune,
    pub rate_control: EncoderRateControl,
    pub scaling_algorithm: Atom,
}

pub fn new(
    env: Env,
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
                    .encoder_output_parameters_h264_low_latency(spec.rate_control.into())
                    .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?,
                EncoderTune::HighQuality => device_resource
                    .encoder_output_parameters_h264_high_quality(spec.rate_control.into())
                    .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?,
            };

            let scaling_algorithm = match spec
                .scaling_algorithm
                .to_term(env)
                .atom_to_string()?
                .as_str()
            {
                "nearest_neighbor" => ScalingAlgorithm::NearestNeighbor,
                "lanczos3" => ScalingAlgorithm::Lanczos3,
                "bilinear" => ScalingAlgorithm::Bilinear,
                _ => {
                    return Err(Error::RaiseTerm(Box::new((
                        unknown_scaling_algorithm(),
                        spec.scaling_algorithm,
                    ))))
                }
            };

            Ok(TranscoderOutputParameters {
                encoder_parameters: AnyEncoderParameters::H264(encoder_parameters),
                output_width: non_zero_width,
                output_height: non_zero_height,
                scaling_algorithm,
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
    let transcoder_mutex = Mutex::new(Some(transcoder));
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
    let transcoder: &mut Transcoder = guard.as_mut().ok_or(Error::RaiseTerm(Box::new(
        "Transcoder resource is not initialized",
    )))?;

    let encoded_input_chunk = EncodedInputChunk {
        data: bytes.as_slice(),
        pts: pts_ns,
    };

    let encoded_output_chunks = transcoder
        .transcode(encoded_input_chunk)
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    let results = process_outputs_chunks(env, encoded_output_chunks);

    Ok(results)
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
    let transcoder: &mut Transcoder = guard.as_mut().ok_or(Error::RaiseTerm(Box::new(
        "Transcoder resource is not initialized",
    )))?;

    let encoded_output_chunks = transcoder
        .flush()
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    let results = process_outputs_chunks(env, encoded_output_chunks);

    Ok(results)
}

fn process_outputs_chunks<'a>(
    env: Env<'a>,
    encoded_outputs_chunks: Vec<Vec<EncodedOutputChunk<Vec<u8>>>>,
) -> Vec<Vec<EncodedFrame<'a>>> {
    encoded_outputs_chunks
        .into_iter()
        .map(|chunks| {
            chunks
                .into_iter()
                .map(|chunk| EncodedFrame {
                    pts_ns: chunk.pts,
                    payload: OwnedBinary::from_iter(chunk.data).release(env),
                })
                .collect()
        })
        .collect()
}
