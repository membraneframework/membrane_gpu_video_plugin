defmodule Encoder.Test do
  use ExUnit.Case, async: false
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.Testing.{Pipeline, Sink}

  @take_refs_snapshot System.get_env("TAKE_TEST_REFERENCES_SNAPSHOT", "") != ""

  @width 1280
  @height 720
  # number of bytes per sample is 1.5 since we use 420 chroma subsampling
  @frame_size_in_bytes round(@width * @height * 1.5)
  @framerate_numerator 25
  @frame_duration_ms div(1000, @framerate_numerator)

  defmodule StreamFormatSwitcher do
    use Membrane.Filter
    def_input_pad :input, accepted_format: _any
    def_output_pad :output, accepted_format: %Membrane.RawVideo{}
    def_options width: [], height: [], framerate: [default: nil]

    @impl true
    def handle_init(_ctx, opts) do
      {[], %{width: opts.width, height: opts.height, framerate: opts.framerate, buffer_cnt: 0}}
    end

    @impl true
    def handle_playing(_ctx, state) do
      {[
         stream_format:
           {:output,
            %Membrane.RawVideo{
              width: state.width,
              height: state.height,
              aligned: true,
              pixel_format: :NV12,
              framerate: state.framerate
            }}
       ], state}
    end

    @impl true
    def handle_stream_format(:input, _stream_format, _ctx, state) do
      {[], state}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      if state.framerate do
        {num, den} = state.framerate
        ts = state.buffer_cnt * Membrane.Time.seconds(Ratio.new(den, num))

        {[buffer: {:output, %{buffer | pts: ts, dts: ts}}],
         %{state | buffer_cnt: state.buffer_cnt + 1}}
      else
        {[buffer: {:output, buffer}], state}
      end
    end
  end

  describe "Encoder encodes" do
    @tag :requires_gpu
    test "raw video frames and produces stream with proper format and proper timestamps" do
      in_path = "./fixtures/ref-10.nv12" |> Path.expand(__DIR__)

      pid =
        Pipeline.start_link_supervised!(
          spec:
            child(:file_src, %Membrane.File.Source{
              chunk_size: @frame_size_in_bytes,
              location: in_path
            })
            |> child(:stream_format_switcher, %StreamFormatSwitcher{
              width: @width,
              height: @height,
              framerate: {@framerate_numerator, 1}
            })
            |> child(:encoder, %Membrane.GPUVideo.Encoder{
              approx_framerate: {@framerate_numerator, 1}
            })
            |> child(:sink, Sink)
        )

      assert_sink_playing(pid, :sink)

      assert_sink_stream_format(
        pid,
        :sink,
        %Membrane.H264{width: 1280, height: 720, alignment: :au, stream_structure: :annexb}
      )

      Enum.each(0..9, fn i ->
        assert_sink_buffer(pid, :sink, buffer)
        assert buffer.pts == Membrane.Time.milliseconds(i * @frame_duration_ms)
      end)

      assert_end_of_stream(pid, :sink, :input)
      Pipeline.terminate(pid)
    end

    @tag :requires_gpu
    @tag :tmp_dir
    test "raw video frames with overriden framerate", ctx do
      in_path = "./fixtures/ref-10.nv12" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "out.nv12")
      ref_path = "./fixtures/ref-10-low_latency-encoder_default.h264" |> Path.expand(__DIR__)

      pid =
        Pipeline.start_link_supervised!(
          spec:
            child(:file_src, %Membrane.File.Source{
              chunk_size: @frame_size_in_bytes,
              location: in_path
            })
            |> child(:stream_format_switcher, %StreamFormatSwitcher{
              width: @width,
              height: @height
            })
            |> child(:encoder, %Membrane.GPUVideo.Encoder{
              approx_framerate: {@framerate_numerator, 1}
            })
            |> child(:sink, %Membrane.File.Sink{location: out_path})
        )

      assert_end_of_stream(pid, :sink, :input)
      Pipeline.terminate(pid)

      if @take_refs_snapshot, do: File.write!(ref_path, File.read!(out_path))
      assert File.read!(out_path) == File.read!(ref_path)
    end

    @tag :requires_gpu
    @tag :tmp_dir
    test "raw video frames without overriden framerate", ctx do
      in_path = "./fixtures/ref-10.nv12" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "out.nv12")
      ref_path = "./fixtures/ref-10-low_latency-encoder_default.h264" |> Path.expand(__DIR__)

      pid =
        Pipeline.start_link_supervised!(
          spec:
            child(:file_src, %Membrane.File.Source{
              chunk_size: @frame_size_in_bytes,
              location: in_path
            })
            |> child(:stream_format_switcher, %StreamFormatSwitcher{
              width: @width,
              height: @height,
              framerate: {@framerate_numerator, 1}
            })
            |> child(:encoder, Membrane.GPUVideo.Encoder)
            |> child(:sink, %Membrane.File.Sink{location: out_path})
        )

      assert_end_of_stream(pid, :sink, :input)

      Pipeline.terminate(pid)

      if @take_refs_snapshot, do: File.write!(ref_path, File.read!(out_path))
      assert File.read!(out_path) == File.read!(ref_path)
    end
  end
end
