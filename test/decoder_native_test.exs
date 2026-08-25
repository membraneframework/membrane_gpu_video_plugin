defmodule Decoder.NativeTest do
  use ExUnit.Case, async: false
  alias Membrane.GPUVideo.{DeviceServer, Native}

  @tag :requires_gpu
  test "Decoder decodes H.264 stream" do
    in_path = "./fixtures/input-100.h264" |> Path.expand(__DIR__)

    assert {:ok, file} = File.read(in_path)
    device = DeviceServer.get_device()
    decoder_ref = Native.new_decoder(device)
    decoded_frames = Native.decode(decoder_ref, file, 0)
    flushed_frames = Native.flush_decoder(decoder_ref)
    all_frames = decoded_frames ++ flushed_frames
    assert length(all_frames) == 100
    [first_frame | _rest_of_frames] = all_frames
    assert first_frame.pts_ns == 0
    assert first_frame.width == 1280
    assert first_frame.height == 720
    assert <<213, 213, 213, 213, _rest::binary>> = first_frame.payload
    Native.destroy(decoder_ref)
  end
end
