use crate::Resource;
use gpu_video::{
    BytesDecoder, EncodedInputChunk, OutputFrame, RawFrameData, parameters::DecoderParameters,
};
use rustler::{Binary, Env, Error, NifStruct, ResourceArc};
use std::sync::Mutex;

pub struct DecoderResource {
    pub decoder_mutex: Mutex<BytesDecoder>,
}

pub struct RawFramePayload(Vec<u8>);

#[rustler::resource_impl]
impl rustler::Resource for RawFramePayload {}

#[derive(NifStruct)]
#[module = "Membrane.GPUVideo.RawFrame"]
pub struct RawFrame<'a> {
    pub payload: Binary<'a>,
    pub pts_ns: Option<u64>,
    pub width: u32,
    pub height: u32,
}

pub fn new(_env: Env, resource: ResourceArc<Resource>) -> Result<ResourceArc<Resource>, Error> {
    let decoder = resource
        .device()
        .ok_or_else(|| Error::RaiseTerm(Box::new("Resource is not a device")))?
        .device
        .create_bytes_decoder_h264(DecoderParameters::default())
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;
    let decoder_mutex = Mutex::new(decoder);
    let decoder = DecoderResource { decoder_mutex };
    let resource = ResourceArc::new(Resource::Decoder(decoder));
    Ok(resource)
}

pub fn decode<'a>(
    env: Env<'a>,
    resource: ResourceArc<Resource>,
    bytes: Binary,
    pts_ns: Option<u64>,
) -> Result<Vec<RawFrame<'a>>, Error> {
    let mut decoder = resource
        .decoder()
        .ok_or_else(|| Error::RaiseTerm(Box::new("Resource is not a decoder")))?
        .decoder_mutex
        .lock()
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    let encoded_input_chunk = EncodedInputChunk {
        data: bytes.as_slice(),
        pts: pts_ns,
    };
    let decoded_frames = decoder
        .decode(encoded_input_chunk)
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;
    Ok(decoded_frames
        .into_iter()
        .map(|frame| into_raw_frame(env, frame))
        .collect())
}

pub fn flush(env: Env, resource: ResourceArc<Resource>) -> Result<Vec<RawFrame>, Error> {
    let mut decoder = resource
        .decoder()
        .ok_or_else(|| Error::RaiseTerm(Box::new("Resource is not a decoder")))?
        .decoder_mutex
        .lock()
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    let flushed_frames = decoder
        .flush()
        .map_err(|err| Error::RaiseTerm(Box::new(err.to_string())))?;

    Ok(flushed_frames
        .into_iter()
        .map(|frame| into_raw_frame(env, frame))
        .collect())
}

fn into_raw_frame(env: Env, frame: OutputFrame<RawFrameData>) -> RawFrame {
    let payload_resource = ResourceArc::new(RawFramePayload(frame.data.frame));
    RawFrame {
        payload: payload_resource.make_binary(env, |payload| payload.0.as_slice()),
        pts_ns: frame.metadata.pts,
        width: frame.data.width,
        height: frame.data.height,
    }
}
