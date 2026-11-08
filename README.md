# ufw-libvirt

Make libvirt guests work on a host running **ufw** with default-deny policies.

One script, four firewall rules, no daemon and no systemd unit.

```bash
git clone https://github.com/636B65/ufw-libvirt.git
cd ufw-libvirt
./ufw-libvirt.sh --dry-run        # see exactly what it will do
sudo ./ufw-libvirt.sh             # apply
```

Non-default network? Set it before you run:

```bash
sudo ./ufw-libvirt.sh --subnet 10.10.0.0/24 --bridge virbr1
# or
sudo LIBVIRT_SUBNET=10.10.0.0/24 ./ufw-libvirt.sh
```

---

## The symptom

Your VMs boot, they get no DNS, and anything that needs the network hangs:

- `ping 1.1.1.1` from a guest **works**
- `ping <your gateway, e.g. 192.168.122.1>` **works**
- every new TCP or UDP connection **times out** — DNS, HTTP, apt, everything
- `tcpdump` in the guest shows the SYN leaving and nothing ever coming back
- the guest's own firewall is empty, so it looks like the host is fine too
- SSH **into** the guest from the host works

Because ICMP works, this reads as "DNS is broken". It isn't. Nothing but ICMP works.

Typical way people hit it: a Terraform or Ansible run that provisions VMs sits for
45 minutes on an `apt` task and then fails, because the guests can't resolve the
package mirror.

## What is actually happening

ufw sets both default policies to drop:

```
/etc/default/ufw:
  DEFAULT_INPUT_POLICY="DROP"
  DEFAULT_FORWARD_POLICY="DROP"
```

Guest traffic needs both chains, and by default no rule permits either:

| Traffic | Chain | Why it's needed |
| --- | --- | --- |
| guest → `virbr0` gateway, udp/tcp 53 | **INPUT** | libvirt runs a `dnsmasq` bound to the bridge address. A query to it is traffic *to the host*. |
| guest → `virbr0` gateway, udp 67 | **INPUT** | Same `dnsmasq` hands out DHCP leases. |
| guest → internet | **FORWARD** | The host routes and NATs it out of the uplink. |

And ICMP works because ufw's shipped `/etc/ufw/before.rules` explicitly accepts
`icmp echo-request` in *both* `ufw-before-input` and `ufw-before-forward`. That one
exception is the entire reason this is so confusing to diagnose.

### Why libvirt's own rules don't save you

Unless told otherwise, libvirt picks the first available backend from
`[nftables, iptables]` — so on any host with `nft` installed, it writes its
forwarding and NAT rules into its **own nftables table**, separate from the `filter`
table ufw manages. The two never consult each other. libvirt's accept rules are
genuinely there, ufw's `FORWARD` drop still happens, and the packet dies anyway.

You'll also find `firewall_backend = "iptables"` in `/etc/libvirt/network.conf`
suggested in forum threads. That moves libvirt's rules into the same `iptables`
table ufw uses, so whether it helps comes down to rule ordering — some people report
it working. It was not tested here, it leaves you mixing backends on a host where ufw
owns the `filter` table, and it does nothing about the INPUT-side DNS and DHCP drops.
This script takes the ufw-native route instead. (If you do try it, libvirt supports
switching while networks are active; the change lands on the next
`libvirtd`/`virtnetworkd` restart.)

## The fix

```bash
ufw allow in on virbr0 from 192.168.122.0/24 to any port 53 proto udp
ufw allow in on virbr0 from 192.168.122.0/24 to any port 53 proto tcp
ufw allow in on virbr0 to any port 67 proto udp
ufw route allow in on virbr0 from 192.168.122.0/24
```

Rule by rule:

1. **DNS over UDP** — the common case, scoped to the bridge *and* the guest subnet.
2. **DNS over TCP** — needed for responses over 512 bytes and for DNSSEC. Skip it and
   you get an intermittent, far worse version of the same bug.
3. **DHCP** — deliberately **not** scoped `from <subnet>`. A guest's first
   `DHCPDISCOVER` is sent from `0.0.0.0` to `255.255.255.255`, before it has an
   address, so a subnet-scoped rule would never match it. This is the single most
   common mistake in hand-rolled versions of this fix.
4. **Forwarding** — `ufw route` writes to the FORWARD chain. Return traffic needs no
   rule: `before.rules` already accepts `RELATED,ESTABLISHED` at the head of the
   forward chain.

### What this deliberately does *not* do

- **`ufw default allow routed`** — works, and opens forwarding for *every* bridge on
  the box, including Docker's. Use the scoped rule instead.
- **`ufw allow in on virbr0`** (unscoped) — accepts any port to the host from guests.
  Fine for a throwaway lab, more than you need.
- **`ufw enable`** — this script never enables ufw. On a remote host, enabling ufw
  with no SSH rule locks you out. If ufw is inactive the rules are still saved, and
  the script tells you so.
- **IPv6** — the stock libvirt `default` network is IPv4-only. If you've added an
  IPv6 subnet, add matching `ufw` rules for it.

## Rebooting

**Nothing extra is required.** `ufw allow` is not a live-only change — it writes the
rule into `/etc/ufw/user.rules`, and `ufw.service` (`ExecStart=/usr/lib/ufw/ufw-init
start`) rebuilds the chains from that file on every boot.

So no `iptables-save`, no `nftables.conf` dump, no custom unit. Adding a second
persistence mechanism is actively harmful: ufw rewrites its chains from its own
files on every reload, so the parallel copy gets clobbered or drifts out of sync.

Two things to confirm, both printed by `--status`:

```bash
systemctl is-enabled ufw            # must be: enabled
grep ENABLED /etc/ufw/ufw.conf      # must be: ENABLED=yes
```

`ENABLED` lives in `/etc/ufw/ufw.conf`, *not* in `/etc/default/ufw`. Its absence from
the latter is normal and not a problem.

One detail that looks like a problem and isn't: `ufw.service` starts
`Before=sysinit.target`, long before libvirt has created `virbr0`. That's fine —
`-i virbr0` matches on interface *name* when a packet arrives, so a rule naming an
interface that doesn't exist yet simply starts working the moment it appears.

Also worth checking, if guests come back unreachable after a reboot — that's libvirt,
not ufw:

```bash
virsh -c qemu:///system net-info default | grep Autostart     # want: yes
```

## Docker

If Docker is running you may have a **second, independent** blocker. Docker installs
a `FORWARD` chain with a drop policy and its own `DOCKER-USER` chain, which is
evaluated before ufw's user chains. Guest traffic then dies even with all four rules
in place.

- If [`ufw-docker`](https://github.com/chaifeng/ufw-docker) is installed, you're
  covered: its first `DOCKER-USER` rule jumps to `ufw-user-forward`, so the
  `ufw route` rule above is honoured. One fix covers both cases.
- If it isn't, the `ufw route` rule gets bypassed and you need to allow the bridge in
  `DOCKER-USER` directly.

The script detects this case and warns rather than changing Docker's chains for you.

Watch out for socket activation: `docker.socket` can be active while
`docker.service` is not, so Docker — and this whole failure mode — can appear the
first time anything touches the Docker API. If guest networking dies right after
something pulls a container, this is why.

## Verifying

```bash
sudo ./ufw-libvirt.sh --status
```

From a guest:

```bash
getent hosts archive.ubuntu.com
curl -sS -o /dev/null -w '%{http_code}\n' http://archive.ubuntu.com/ubuntu/dists/noble/Release
```

On the host, the evidence either way is in the kernel log. Before the fix you'll see
a pile of these, all to port 53:

```
[UFW BLOCK] IN=virbr0 OUT=eth0  SRC=192.168.122.50 DST=1.1.1.1        PROTO=TCP DPT=53   <- FORWARD drop
[UFW BLOCK] IN=virbr0 OUT=      SRC=192.168.122.50 DST=192.168.122.1  PROTO=UDP DPT=53   <- INPUT drop
```

After it, silence:

```bash
journalctl -k -f | grep 'UFW BLOCK.*virbr0'
```

Note that `OUT=` being empty means the packet was headed for the host itself (INPUT);
a populated `OUT=` means it was being routed (FORWARD). Which one you see tells you
which rule is missing.

## Undo

```bash
sudo ./ufw-libvirt.sh --remove
```

Deletes exactly the four rules it added, with the same subnet and bridge arguments
you applied them with. Pass the same `--subnet`/`--bridge` you used, or it won't
match.

## Options

```
--subnet CIDR    guest network, default 192.168.122.0/24
--bridge IFACE   libvirt bridge, default virbr0
--network NAME   libvirt network to cross-check against, default "default"
--dry-run        print the ufw commands without running them
--status         show whether the rules are loaded, and recent blocks
--remove         delete the rules this script adds
-h, --help       help
```

Defaults also come from the environment (`LIBVIRT_SUBNET`, `LIBVIRT_BRIDGE`,
`LIBVIRT_NETWORK`), or you can edit the block at the top of the script. When `virsh`
is available the script cross-checks your values against the real libvirt network and
warns on a mismatch — it warns rather than overriding, so an explicit argument always
wins.

Re-running is safe: ufw skips rules that already exist.

## Requirements

`ufw`, `bash` 4+, and root for anything but `--dry-run`. `virsh` is optional and used
only for the sanity check. Tested against ufw 0.36.x on Arch; the logic is
distribution-independent, though `/etc/default/ufw` and `ufw.service` paths vary a
little between distros.

## Prior art

- [`chaifeng/ufw-docker`](https://github.com/chaifeng/ufw-docker) — the same class of
  problem for Docker's bridges, and what makes the two fixes compose.
- [`palazzem/hanzo` #366](https://github.com/palazzem/hanzo/pull/366) — "allow libvirt
  guests through UFW", the same diagnosis and essentially the same four rules, applied
  inside an Ansible role.

## License

MIT
