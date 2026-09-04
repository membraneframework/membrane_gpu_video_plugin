use crate::{EncodedFrame, Resource};
use gpu_video::parameters::{EncoderParametersH264, RateControl, Rational, VideoParameters};
use gpu_video::{BytesEncoderH264, InputFrame, RawFrameData};
use rustler::{Binary, Env, NifStruct, NifUnitEnum, OwnedBinary};
use rustler::{Error, NifTaggedEnum, ResourceArc};
use std::sync::Mutex;

pub struct EncoderResource {
    pub encoder_mutex: Mutex<Option<BytesEncoderH264>>,
    pub width: u32,
    pub height: u32,
}

#[derive(NifUnitEnum, Clone, Copy)]
pub enum EncoderTune {
    LowLatency,
    HighQuality,
}

#[derive(NifStruct, Clone, Copy)]
#[module = "Membrane.GPUVideo.Encoder.VariableBitrate"]
pub struct VariableBitrate {
    pub average_bitrate: u64,
    pub max_bitrate: u64,
    pub virtual_buffer_size_ms: u64,
}

#[derive(NifStruct, Clone, Copy)]
#[module = "Membrane.GPUVideo.Encoder.ConstantBitrate"]
pub struct ConstantBitrate {
    pub bitrate: u64,
    pub virtual_buffer_size_ms: u64,
}

#[derive(NifTaggedEnum, Clone, Copy)]
pub enum EncoderRateControl {
    EncoderDefault,
    VariableBitrate(VariableBitrate),
    ConstantBitrate(ConstantBitrate),
    Disabled,
}

impl From<EncoderRateControl> for RateControl {
    fn from(rc: EncoderRateControl) -> Self {
        match rc {
            EncoderRateControl::EncoderDefault => RateControl::EncoderDefault,
            EncoderRateControl::ConstantBitrate(config) => RateControl::ConstantBitrate {
                bitrate: config.bitrate,
                virtual_buffer_size: std::time::Duration::from_millis(
                    config.virtual_buffer_size_ms,
                ),
            },
            EncoderRateControl::VariableBitrate(config) => RateControl::VariableBitrate {
                average_bitrate: config.average_bitrate,
                max_bitrate: config.max_bitrate,
                virtual_buffer_size: std::time::Duration::from_millis(
                    config.virtual_buffer_size_ms,
                ),
            },

            EncoderRateControl::Disabled => RateControl::Disabled,
        }
    }
}

pub fn new(
    _env: Env,
    resource: ResourceArc<Resource>,
    width: u32,
    height: u32,
    approx_framerate: (u32, u32),
    tune: EncoderTune,
    rate_control: EncoderRateControl,
) -> Result<ResourceArc<Resource>, Error> {
    let device_resource = &resource
        .device()
        .ok_or_else(|| Error::RaiseTerm(Box::new("Resource is not a device")))?
        .device;
    let non_zero_width = std::num::NonZero::new(width).ok_or(Error::RaiseTerm(Box::new(
        "Improper width: width must be non-zero",
    )))?;
    let non_zero_height = std::num::NonZero::new(height).ok_or(Error::RaiseTerm(Box::new(
        "Improper height: height must be non-zero",
    )))?;

    let video_parameters = VideoParameters {
        width: non_zero_width,
        height: non_zero_height,
        target_framerate: Rational {
            numerator: approx_framerate.0,
            denominator: std::num::NonZero::new(approx_framerate.1).ok_or(Error::RaiseTerm(Box::new(
                "Improper approx_framerate denominator: approx_framerate denominator must be non-zero",
            )))?,
        },
    };

    let output_parameters = match tune {
        EncoderTune::LowLatency => device_resource
            .encoder_output_parameters_h264_low_latency(rate_control.into())
            .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?,
        EncoderTune::HighQuality => device_resource
            .encoder_output_parameters_h264_high_quality(rate_control.into())
            .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?,
    };

    let encoder = device_resource
        .create_bytes_encoder_h264(EncoderParametersH264 {
            input_parameters: video_parameters,
            output_parameters,
        })
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;
    let encoder_mutex = Mutex::new(Some(encoder));
    let encoder = EncoderResource {
        encoder_mutex,
        width,
        height,
    };

    let resource = ResourceArc::new(Resource::Encoder(encoder));
    Ok(resource)
}

pub fn encode<'a>(
    env: Env<'a>,
    resource: ResourceArc<Resource>,
    bytes: Binary,
    pts_ns: Option<u64>,
) -> Result<EncodedFrame<'a>, Error> {
    let encoder = resource
        .encoder()
        .ok_or_else(|| Error::RaiseTerm(Box::new("Resource is not an encoder")))?;
    let frame = InputFrame {
        data: RawFrameData {
            frame: bytes.to_vec(),
            width: encoder.width,
            height: encoder.height,
        },
        pts: pts_ns,
    };

    let mut guard = encoder
        .encoder_mutex
        .lock()
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    let encoder: &mut BytesEncoderH264 = guard
        .as_mut()
        .ok_or(Error::RaiseTerm(Box::new("Encoder is not initialized")))?;

    let encoded_frame = encoder
        .encode(&frame, false)
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    let len = encoded_frame.data.len();
    let mut payload =
        OwnedBinary::new(len).ok_or(Error::RaiseTerm(Box::new("Couldn't create OwnedBinary")))?;
    payload.as_mut_slice().copy_from_slice(&encoded_frame.data);

    Ok(EncodedFrame {
        payload: payload.release(env),
        pts_ns: encoded_frame.pts,
    })
}
