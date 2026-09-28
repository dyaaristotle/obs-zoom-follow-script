# OBS Zoom, Follow Mouse and More - macOS Fork

This repository contains a macOS-focused improvement of an OBS Lua script for zooming into the area under the mouse and following the mouse while recording or streaming.

## Original Project and Attribution

This project is a derivative work. It was originally copied from and based on the v2.2.0 release of Edoardo Guzzi's project:

- Original author: Edoardo Guzzi, GitHub user [@mredodos](https://github.com/mredodos)
- Original repository: [mredodos/zoom-and-follow-and-more-eg](https://github.com/mredodos/zoom-and-follow-and-more-eg)
- Original OBS resource: [OBS Lua - Zoom and Follow Mouse and More](https://obsproject.com/forum/resources/zoom-and-follow-mouse-and-more-by-edoardo-guzzi.2289/)
- Original license: GNU GPL v3.0

The original author and upstream project remain credited. This fork is not affiliated with Edoardo Guzzi or the OBS Project.

## Improvements in This Fork

Compared with the upstream base version, this fork was modified for a macOS screen-recording workflow with OBS Studio 32.2.2:

- Uses macOS CoreGraphics to read the global mouse position
- Fixes Retina, HiDPI, and multi-monitor coordinate mapping
- Combines crop filtering with scene-item transforms to produce real visual magnification
- Moves the source pixel under the mouse to the center of the OBS canvas when Follow is enabled
- Anchors the Zoom In animation to the mouse position at the moment the hotkey is pressed
- Uses the same center-follow model for horizontal and vertical movement
- Clamps movement at source edges to avoid exposing blank areas
- Adds detailed timestamped and sequenced debug logging
- Supports square OBS canvases such as 1664x1664

## Platform Scope

This is a macOS-only improved fork. It has been tested on macOS and is not intended or supported for Windows or Linux.

The key improvements depend on:

- macOS CoreGraphics
- macOS Screen Recording permission
- OBS 32 scene-item transform APIs
- macOS Retina and multi-monitor coordinate mapping

The upstream project contains Windows and Linux code paths, but the centered-follow and mouse-anchored zoom changes in this fork should not be assumed to work on other platforms.

## Tested Environment

- macOS
- Apple Silicon MacBook Air
- OBS Studio 32.2.2
- OBS canvas: 1664x1664
- macOS Screen Capture
- Example source resolution: 5120x1440

## Installation

1. Download [`zoom-follow-mouse-and-more-eg.lua`](./zoom-follow-mouse-and-more-eg.lua).
2. Open OBS Studio.
3. Go to `Tools -> Scripts`, click `+`, and select the Lua file.
4. Assign hotkeys for Zoom and Follow in `Settings -> Hotkeys`.
5. Select the capture source in OBS and press `Ctrl+F` to fit it to the canvas before using Zoom.

macOS must allow OBS to capture the screen:

`System Settings -> Privacy & Security -> Screen & System Audio Recording`

Restart OBS after changing this permission if the capture remains black or unavailable.

## Usage

- Press the Zoom hotkey to zoom in around the current mouse position.
- Press the Zoom hotkey again to zoom out and restore the original scene-item transform.
- Press the Follow hotkey to enable or disable mouse following.
- Set Follow Speed to `1.0` for immediate centering.
- Use a lower Follow Speed for smoother camera movement.

For troubleshooting, enable Debug Mode in the script settings and inspect the OBS script logs.

## Known Limitations

- This fork is macOS-only. Windows and Linux support is not guaranteed.
- Near a source edge, the script prioritizes avoiding blank output. As a result, the mouse-related content may not be mathematically centered when the source does not contain enough pixels beyond that edge.
- Direct screen-capture sources are recommended. Complex nested scenes, rotations, and non-standard transforms may require additional adaptation.
- OBS may need to be restarted after changing macOS Screen Recording permission.

## License

This fork is derived from a GPL-3.0 project and remains under the GNU GPL v3.0. Keep the original author and upstream project attribution when using, modifying, or redistributing this work.

