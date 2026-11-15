# Contributing to Reach

Start with the README build steps and `scripts/verify.sh --all`. Discuss substantial changes in an issue before implementing them. Small focused fixes, documentation improvements and reproducible bug reports are welcome.

Preserve the core interaction: one finger controls the pointer/direct touch; two fingers pan/zoom; three-finger tap opens displays. The overlay scroll rail must not cause layout reflow. Keep pairing, identity pins, role validation and preapproval traffic boundaries intact. Do not silently disable TLS validation, add private Apple APIs, log input/clipboard/rooms or introduce a dependency on a maintainer-hosted service.

For a pull request, describe the user-visible problem, resulting behavior, checks run and known limitations. Add meaningful regression coverage when behavior changes. Say exactly which physical devices/network routes were tested. Never infer real-device interaction, performance or security assurance from a build passing.

Do not commit signing credentials, provisioning profiles, invitations, room secrets, `.env` files, personal desktop captures or local build results. Report security issues privately; see SECURITY.md.

By contributing, you agree to license your original contribution under this repository's MIT license. Keep third-party notices intact. Be respectful and constructive; maintainers may close abusive or off-topic discussions.
