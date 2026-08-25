defmodule Encoder.NativeTest do
  use ExUnit.Case, async: false
  alias Membrane.GPUVideo.{DeviceServer, Native}

  @take_refs_snapshot System.get_env("TAKE_TEST_REFERENCES_SNAPSHOT", "") != ""

  @width 1280
  @height 720
  # number of bytes per sample is 1.5 since we use 420 chroma subsampling
  @frame_size_in_bytes round(@width * @height * 1.5)
  @framerate {25, 1}

  for tune <- [:low_latency, :high_quality],
      rate_control <- [
        :encoder_default,
        :disabled,
        {:constant_bitrate,
         %Membrane.GPUVideo.Encoder.ConstantBitrate{
           virtual_buffer_size_ms: 2000,
           bitrate: 8000
         }},
        {:variable_bitrate,
         %Membrane.GPUVideo.Encoder.VariableBitrate{
           virtual_buffer_size_ms: 2000,
           average_bitrate: 2000,
           max_bitrate: 4000
         }}
      ] do
    {tune, rate_control}
  end
  |> Enum.map(fn {tune, rate_control} ->
    rate_control_type = if is_tuple(rate_control), do: elem(rate_control, 0), else: rate_control
    rate_control_ast = Macro.escape(rate_control)
    @tag :requires_gpu
    test "Encoder encodes raw frames in NV12 format into H.264 stream with the following arguments - tune: #{tune}, rate_control: #{rate_control_type}" do
      in_path = "./fixtures/ref-10.nv12" |> Path.expand(__DIR__)

      ref_path =
        "./fixtures/ref-10-#{unquote(tune)}-#{unquote(rate_control_type)}.h264"
        |> Path.expand(__DIR__)

      assert {:ok, file} = File.read(in_path)

      device = DeviceServer.get_device()

      encoder_ref =
        Native.new_encoder(
          device,
          @width,
          @height,
          @framerate,
          unquote(tune),
          unquote(rate_control_ast)
        )

      raw_frames = for <<chunk::size(@frame_size_in_bytes)-binary <- file>>, do: chunk

      encoded_frames =
        Enum.map(raw_frames, fn raw_frame ->
          encoded_frame =
            Native.encode(encoder_ref, raw_frame)

          encoded_frame.payload
        end)

      if @take_refs_snapshot, do: File.write!(ref_path, Enum.join(encoded_frames))
      assert File.read!(ref_path) == Enum.join(encoded_frames)

      Native.destroy(encoder_ref)
    end
  end)
end
