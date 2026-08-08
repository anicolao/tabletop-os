# SSH public keys allowed to log in as `admin`.
#
# These are *public* keys and are meant to be committed.
#
# This file is load-bearing: modules/base.nix sets `users.mutableUsers = false`
# and no passwords anywhere, so these keys are the only way into a flashed
# board. If this list is empty the build fails an assertion rather than
# producing an image nobody can log into — that is deliberate.
#
# Add a key here, rebuild, reflash. There is no runtime way to add one.
[
  # Alex's personal key — the same one already trusted by nix-darwin-config.
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCbQGcmXgLXRs97+sEURtSWXvejWmg6I5rRWTpH8XH7DhxMTVSTV6xNus4UXEzIKjs8AxZ8DsBPoB50DHq7lQXpOfaku/6lx5up4mhSB5LCexBLdDW0tdJmfDnDGXrS0ytQNqovlCj8svyZFLFltEIZRWKpCgc2dHvUWdxZHzIqm1ZIkrTJrA5SuD4M4AgDCHlj3cY45GCSsa+Vvy00nylx+j/VwNocyAHMGWFiczOzuRpq6AX4qI+T2+iPZQrxRDkW8BWd1oYbNHXOgypKJRNH87EHt/pVS+2unBsi86A7e08e9Du9/idDHYZg6RCmOM6CTmF5N7OMCnO2bIgsrNvykZkCEvNKW6XbY+wb8Y3hzXDBUWSY+jQp/xZVTbzPG/UWvxxydlCc0h0GgXsccIskLMGv5Yp083q/mzQY+TqxaYExhWTGCHRli5oEWysFnbx+Bjty/stZGjVbVjdpVc5ZjnSD0UDfyTt6Bkg3BUsjLCeY3w9yzBorkRzPS2aHBHc= anicolao@shostakovich.cottage"

  # The key turing uses to reach remote Nix builders. Present so the Orange Pi
  # can be enlisted as an aarch64-linux builder without a reflash — see
  # docs/BUILDING.md.
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDPX692qGpHdk1/r54zOvEE208Itd2z0Bma1jOWCT6j nix-remote-builder"
]
