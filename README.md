# NetCap

NetCap is an Omarchy bar widget for tracking monthly network usage and shaping
the active default network interface.

## Features

- Tracks received and transmitted bytes for the current default route.
- Saves monthly totals under `~/.local/state/omarchy-netcap/`.
- Applies upload and download caps after explicit user approval.
- Automatically switches to the configured lower speeds when the quota is
  reached, while the Omarchy shell is running and caps have been enabled.
- Removes only its own traffic-control rules when caps are cleared.

## Install

```bash
omarchy plugin add https://github.com/GrantedMeFluffy/omarchy-netcap.git --enable
```

Move **NetCap** into the bar using the Omarchy bar settings. Configure the
monthly quota and speeds in the plugin settings. Open its bar panel and choose
**Apply caps** to start shaping. This action requires administrator approval
through `pkexec`. Once shaping is enabled, reaching the monthly quota applies
the lower configured speeds automatically.

## Requirements and limitations

- Omarchy, `iproute2` (`ip` and `tc`), `jq`, and `pkexec`.
- The default route must use a supported interface with an ordinary
  `fq_codel` or `pfifo_fast` root qdisc. NetCap refuses to replace an HTB or
  other custom qdisc, an existing ingress setup, or an existing `netcap0`
  device it does not own. A root-owned marker in `/run/omarchy-netcap/`
  records the original qdisc and is required before NetCap will update or
  remove traffic-control rules.
- Download shaping uses an IFB device and Linux traffic control; upload
  shaping uses HTB. Applying caps replaces the active interface's supported
  root qdisc while enabled. Removing caps restores the recorded root qdisc and
  removes only traffic-control rules that match NetCap's recorded state.
- Usage starts at the first sample after the widget is installed/enabled.
  Counters are sampled every 10 seconds while the Omarchy shell is running.
  Traffic during a shell shutdown or before its first sample is not counted.
- Monthly totals reset at the beginning of the local calendar month.
- The plugin does not change network limits unless **Apply caps** is clicked.
  If authorization is cancelled or fails, no limit change is reported as
  successful.

## Upgrading from earlier versions

If an earlier NetCap version has already applied caps, choose **Remove caps**
in that version before updating. New versions require a root-owned ownership
marker and deliberately refuse to adopt an existing unmarked HTB tree. This
prevents NetCap from claiming or deleting traffic-control rules created by
another tool.

## Uninstall

Remove active caps from the widget before uninstalling:

```bash
omarchy plugin disable io.github.grantedmefluffy.omarchy-netcap
omarchy plugin remove io.github.grantedmefluffy.omarchy-netcap
```

## License

MIT. See [LICENSE](LICENSE).
