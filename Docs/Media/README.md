# Demo capture

The 30-second release video uses real Reach client footage captured in iOS Simulator, connected to an isolated development Mac host over Reach's authenticated encrypted local transport. A native AppKit sample workspace provides non-private desktop content on the Mac displays. Desktop frames are streamed through the normal capture/codec path; the phone UI is not a rendered mockup.

The recording host uses a separate test identity namespace, a demo device name and no private relay configuration. No installed personal Mac/iPhone app or trusted device was replaced. Simulator signing was enabled for Keychain access. The UI capture check exercised framing presets, pinch zoom, monitor browsing, the actual hold-to-scroll rail and keyboard text entry. It is not a physical-device, cellular, latency or battery benchmark.

Footage is edited for pacing, with a short closing hold. Narration was generated locally in Voicebox using the approved Kokoro Heart preset. There is no music. The supplied subtitle timings are approximate and should be reviewed in the publishing platform's preview.

The README uses a silent looping GIF preview linked to the full narrated MP4 release asset. The MP4 is 1080×1350 (4:5), H.264/AAC at 30 fps, suitable for native LinkedIn feed upload. Revised narration and captions focus on the interaction, including hold-to-scroll, variable speed and release-to-stop.
