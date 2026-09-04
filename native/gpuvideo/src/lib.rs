use decoder::{DecoderResource, RawFrame};
use encoder::{EncoderRateControl, EncoderResource, EncoderTune};
use gpu_video::{
    VulkanDevice,
    parameters::{VulkanAdapterDescriptor, VulkanDeviceDescriptor},
};
use rustler::{Atom, Binary, Env, Error, ResourceArc, types::atom};
use std::sync::Arc;
use transcoder::{OutputSpec, TranscoderResource};

pub mod decoder;
pub mod encoder;
pub mod transcoder;

pub enum Resource {
    Encoder(EncoderResource),
    Decoder(DecoderResource),
    Transcoder(TranscoderResource),
    Device(DeviceResource),
}

#[rustler::resource_impl]
impl rustler::Resource for Resource {}

pub struct DeviceResource {
    pub device: Arc<VulkanDevice>,
}

impl std::panic::RefUnwindSafe for DeviceResource {}

impl Resource {
    pub fn encoder(&self) -> Option<&EncoderResource> {
        match self {
            Self::Encoder(encoder_resource) => Some(encoder_resource),
            _ => None,
        }
    }

    pub fn decoder(&self) -> Option<&DecoderResource> {
        match self {
            Self::Decoder(decoder_resource) => Some(decoder_resource),
            _ => None,
        }
    }

    pub fn transcoder(&self) -> Option<&TranscoderResource> {
        match self {
            Self::Transcoder(transcoder_resource) => Some(transcoder_resource),
            _ => None,
        }
    }

    pub fn device(&self) -> Option<&DeviceResource> {
        match self {
            Self::Device(device_resource) => Some(device_resource),
            _ => None,
        }
    }
}

#[derive(rustler::NifStruct)]
#[module = "Membrane.GPUVideo.EncodedFrame"]
pub struct EncodedFrame<'a> {
    pub payload: Binary<'a>,
    pub pts_ns: Option<u64>,
}

#[rustler::nif(schedule = "DirtyIo")]
fn create_device() -> Result<ResourceArc<Resource>, Error> {
    let instance = gpu_video::VulkanInstance::new()
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    let adapter_descriptor = VulkanAdapterDescriptor {
        supports_decoding: true,
        supports_encoding: true,
    };
    let adapter = instance
        .create_adapter(&adapter_descriptor)
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    let device_descriptor = VulkanDeviceDescriptor::default();
    let device = adapter
        .create_device(&device_descriptor)
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    let device_resource = ResourceArc::new(Resource::Device(DeviceResource { device }));
    Ok(device_resource)
}

#[rustler::nif(schedule = "DirtyIo")]
fn new_decoder(env: Env, resource: ResourceArc<Resource>) -> Result<ResourceArc<Resource>, Error> {
    decoder::new(env, resource)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn decode<'a>(
    env: Env<'a>,
    resource: ResourceArc<Resource>,
    bytes: Binary,
    pts_ns: Option<u64>,
) -> Result<Vec<RawFrame<'a>>, Error> {
    decoder::decode(env, resource, bytes, pts_ns)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn flush_decoder(env: Env, resource: ResourceArc<Resource>) -> Result<Vec<RawFrame>, Error> {
    decoder::flush(env, resource)
}

#[rustler::nif(schedule = "DirtyIo")]
fn new_encoder(
    env: Env,
    resource: ResourceArc<Resource>,
    width: u32,
    height: u32,
    frame_rate: (u32, u32),
    tune: EncoderTune,
    rate_control: EncoderRateControl,
) -> Result<ResourceArc<Resource>, Error> {
    encoder::new(env, resource, width, height, frame_rate, tune, rate_control)
}

#[rustler::nif(schedule = "DirtyIo")]
fn encode<'a>(
    env: Env<'a>,
    resource: ResourceArc<Resource>,
    bytes: Binary,
    pts_ns: Option<u64>,
) -> Result<EncodedFrame<'a>, Error> {
    encoder::encode(env, resource, bytes, pts_ns)
}

#[rustler::nif(schedule = "DirtyIo")]
#[allow(unused_variables)]
fn destroy<'a>(env: Env<'a>, resource: ResourceArc<Resource>) -> Result<Atom, Error> {
    if let Resource::Encoder(encoder) = &*resource {
        let mut encoder = encoder
            .encoder_mutex
            .lock()
            .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;
        *encoder = None;
    }

    Ok(atom::ok())
}

#[rustler::nif(schedule = "DirtyIo")]
fn new_transcoder(
    env: Env,
    resource: ResourceArc<Resource>,
    output_specs: Vec<OutputSpec>,
    approx_framerate: (u32, u32),
) -> Result<ResourceArc<Resource>, Error> {
    transcoder::new(env, resource, output_specs, approx_framerate)
}

#[rustler::nif(schedule = "DirtyIo")]
fn transcode<'a>(
    env: Env<'a>,
    resource: ResourceArc<Resource>,
    bytes: Binary,
    pts_ns: Option<u64>,
) -> Result<Vec<Vec<EncodedFrame<'a>>>, Error> {
    transcoder::transcode(env, resource, bytes, pts_ns)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn flush_transcoder<'a>(
    env: Env<'a>,
    resource: ResourceArc<Resource>,
) -> Result<Vec<Vec<EncodedFrame<'a>>>, Error> {
    transcoder::flush(env, resource)
}

rustler::init!("Elixir.Membrane.GPUVideo.Native");
