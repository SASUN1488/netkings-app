# NetKings VPN

Client app for the NetKings VPN subscription (Flutter: Android, Windows, Linux). The core is
[sing-box](https://github.com/SagerNet/sing-box) (GPLv3); the subscription server (vpnctl) returns ready
sing-box outbounds for User-Agent `NetKings/...` and the app only adds the TUN inbound, DNS and routing.

## Layout

- `lib/` — UI (`main.dart`), subscription fetch/cache (`src/subscription.dart`), sing-box config
  (`src/singbox.dart`), VPN control (`src/vpn.dart`: Android channels / `src/desktop_core.dart`: desktop process).
- `android/app/src/main/kotlin/.../NkVpnService.kt` — VpnService with libbox (sing-box as a library).
- `core/` — sing-box CLI for desktop, bundled next to the app by the Linux / Windows CMake install rules.
- `packaging/` — Linux installer script and icon.

## Building the native parts (not in git)

sing-box v1.14.4 sources in `../sing-box`:

```sh
# Android core -> android/app/libs/libbox.aar (gomobile/gobind from github.com/sagernet/gomobile v0.1.12)
gomobile bind -target android/arm64,android/arm,android/amd64 -androidapi 23 -javapkg=io.nekohasekai -libname=box \
  -trimpath -ldflags "-X github.com/sagernet/sing-box/constant.Version=1.14.4 -s -w -buildid= -checklinkname=0" \
  -tags with_gvisor,with_quic,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0 \
  -o android/app/libs/libbox.aar ./experimental/libbox
# desktop cores
L="-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=1.14.4"; T=with_gvisor,with_quic,with_utls,with_clash_api
CGO_ENABLED=0 go build -trimpath -ldflags "$L" -tags $T -o core/linux/sing-box ./cmd/sing-box
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "$L" -tags $T -o core/windows/sing-box.exe ./cmd/sing-box
```

## Builds

- Android: `flutter build apk --release --split-per-abi` (release key from `~/dev/keys/key.properties`).
- Linux: `flutter build linux --release`, then pack `bundle/` with `packaging/install-linux.sh`
  (tar, not AppImage: the core gets CAP_NET_ADMIN with setcap on first connect).
- Windows: `flutter build windows --release` on Windows (the app requires admin: TUN / wintun).

## License

GPL-3.0 (see `LICENSE`), as required by the bundled sing-box core.
