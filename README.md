# Membrane vk video plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_vk_video_plugin.svg)](https://hex.pm/packages/membrane_vk_video_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_vk_video_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_vk_video_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_vk_video_plugin)

Membrane H.264 decoder based on [vk-video](https://crates.io/crates/vk-video).
It's a part of the [Membrane Framework](https://membrane.stream).

## Installation

The package can be installed by adding `membrane_vk_video_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_vk_video_plugin, "~> 0.2.2"}
  ]
end
```

This package depends on hardware encoding acceleration capabilities provided by [Vulkan video exensions](https://www.khronos.org/blog/an-introduction-to-vulkan-video) and works only on Linux with NVIDIA or AMD GPUs with Mesa drivers. For more information see the README of the [`vk-video`](https://crates.io/crates/vk-video) Rust package.


## Copyright and License

Copyright 2025, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_vk_video_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_vk_video_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
