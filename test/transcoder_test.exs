defmodule Transcoder.Test do
  use ExUnit.Case, async: false
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  require Membrane.Pad, as: Pad
  alias Membrane.GPUVideo.Transcoder
  alias Membrane.Testing.{Pipeline, Sink}

  @take_refs_snapshot System.get_env("TAKE_TEST_REFERENCES_SNAPSHOT", "") != ""

  @framerate_numerator 25
  @frame_duration_ms div(1000, @framerate_numerator)

  describe "Transcoder" do
    @tag :requires_gpu
    test "sends correct stream format for each output pad" do
      in_path = "./fixtures/input-10.h264" |> Path.expand(__DIR__)

      pid =
        Pipeline.start_link_supervised!(
          spec: [
            child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
            |> child(:parser, %Membrane.H264.Parser{
              generate_best_effort_timestamps: %{framerate: {@framerate_numerator, 1}}
            })
            |> child(:transcoder, %Transcoder{approx_framerate: {25, 1}}),
            get_child(:transcoder)
            |> via_out(Pad.ref(:output, 0),
              options: [width: 1280, height: 720]
            )
            |> child(:sink_0, Sink),
            get_child(:transcoder)
            |> via_out(Pad.ref(:output, 1),
              options: [width: 640, height: 360]
            )
            |> child(:sink_1, Sink)
          ]
        )

      assert_sink_playing(pid, :sink_0)
      assert_sink_playing(pid, :sink_1)

      assert_sink_stream_format(pid, :sink_0, %Membrane.H264{
        width: 1280,
        height: 720,
        alignment: :au,
        stream_structure: :annexb,
        framerate: {25, 1}
      })

      assert_sink_stream_format(pid, :sink_1, %Membrane.H264{
        width: 640,
        height: 360,
        alignment: :au,
        stream_structure: :annexb,
        framerate: {25, 1}
      })

      assert_end_of_stream(pid, :sink_0, :input)
      assert_end_of_stream(pid, :sink_1, :input)
      Pipeline.terminate(pid)
    end

    @tag :requires_gpu
    test "produces buffers on all outputs and forwards end of stream" do
      in_path = "./fixtures/input-10.h264" |> Path.expand(__DIR__)

      pid =
        Pipeline.start_link_supervised!(
          spec: [
            child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
            |> child(:parser, %Membrane.H264.Parser{
              generate_best_effort_timestamps: %{framerate: {@framerate_numerator, 1}}
            })
            |> child(:transcoder, %Transcoder{approx_framerate: {25, 1}}),
            get_child(:transcoder)
            |> via_out(Pad.ref(:output, 0),
              options: [width: 1280, height: 720]
            )
            |> child(:sink_0, Sink),
            get_child(:transcoder)
            |> via_out(Pad.ref(:output, 1),
              options: [width: 640, height: 360]
            )
            |> child(:sink_1, Sink)
          ]
        )

      Enum.each(0..9, fn i ->
        assert_sink_buffer(pid, :sink_0, buffer_0)
        assert buffer_0.pts == Membrane.Time.milliseconds(i * @frame_duration_ms)

        assert_sink_buffer(pid, :sink_1, buffer_1)
        assert buffer_1.pts == Membrane.Time.milliseconds(i * @frame_duration_ms)
      end)

      assert_end_of_stream(pid, :sink_0, :input)
      assert_end_of_stream(pid, :sink_1, :input)
      Pipeline.terminate(pid)
    end

    @tag :requires_gpu
    @tag :tmp_dir
    test "produces desired output as specified by the config", %{tmp_dir: tmp_dir} do
      in_path = "./fixtures/input-10.h264" |> Path.expand(__DIR__)
      output1 = Path.join(tmp_dir, "output1.h264")
      output2 = Path.join(tmp_dir, "output2.h264")
      ref1 = "./fixtures/ref-1280x720.h264" |> Path.expand(__DIR__)
      ref2 = "./fixtures/ref-640x360.h264" |> Path.expand(__DIR__)

      pid =
        Pipeline.start_link_supervised!(
          spec: [
            child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
            |> child(:parser, %Membrane.H264.Parser{
              generate_best_effort_timestamps: %{framerate: {@framerate_numerator, 1}}
            })
            |> child(:transcoder, %Transcoder{approx_framerate: {25, 1}}),
            get_child(:transcoder)
            |> via_out(Pad.ref(:output, 0),
              options: [width: 1280, height: 720]
            )
            |> child(:sink_0, %Membrane.File.Sink{location: output1}),
            get_child(:transcoder)
            |> via_out(Pad.ref(:output, 1),
              options: [width: 640, height: 360]
            )
            |> child(:sink_1, %Membrane.File.Sink{location: output2})
          ]
        )

      assert_end_of_stream(pid, :sink_0, :input)
      assert_end_of_stream(pid, :sink_1, :input)
      Pipeline.terminate(pid)

      if @take_refs_snapshot, do: File.write!(ref1, File.read!(output1))
      if @take_refs_snapshot, do: File.write!(ref2, File.read!(output2))
      assert File.read!(output1) == File.read!(ref1)
      assert File.read!(output2) == File.read!(ref2)
    end

    @tag :requires_gpu
    test "works with a single output pad" do
      in_path = "./fixtures/input-10.h264" |> Path.expand(__DIR__)

      pid =
        Pipeline.start_link_supervised!(
          spec: [
            child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
            |> child(:parser, %Membrane.H264.Parser{
              generate_best_effort_timestamps: %{framerate: {@framerate_numerator, 1}}
            })
            |> child(:transcoder, %Transcoder{approx_framerate: {25, 1}}),
            get_child(:transcoder)
            |> via_out(Pad.ref(:output, 0),
              options: [width: 1280, height: 720]
            )
            |> child(:sink_0, Sink)
          ]
        )

      assert_sink_stream_format(pid, :sink_0, %Membrane.H264{
        width: 1280,
        height: 720,
        alignment: :au,
        stream_structure: :annexb
      })

      assert_end_of_stream(pid, :sink_0, :input)
      Pipeline.terminate(pid)
    end

    @tag :requires_gpu
    test "raises when an output pad is linked after the element starts playing" do
      in_path = "./fixtures/input-10.h264" |> Path.expand(__DIR__)

      {:ok, _sup, pid} =
        Pipeline.start(
          spec: [
            child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
            |> child(:parser, %Membrane.H264.Parser{
              generate_best_effort_timestamps: %{framerate: {@framerate_numerator, 1}}
            })
            |> child(:transcoder, %Transcoder{approx_framerate: {25, 1}}),
            get_child(:transcoder)
            |> via_out(Pad.ref(:output, 0),
              options: [width: 1280, height: 720]
            )
            |> child(:sink_0, Sink)
          ]
        )

      Pipeline.execute_actions(pid,
        spec:
          get_child(:transcoder)
          |> via_out(Pad.ref(:output, 1),
            options: [width: 640, height: 360]
          )
          |> child(:sink_1, Sink)
      )

      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:membrane_child_crash, :transcoder, {%RuntimeError{}, _stack}}},
                     5000
    end
  end
end
