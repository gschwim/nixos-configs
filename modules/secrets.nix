{ ... }:
{
  # agenix's decryption identity on every host. Was `/etc/ssh/ssh_host_ed25519_key`
  # which created a chicken-and-egg blocking declarative management of the
  # SSH host key (couldn't encrypt the key to itself). The bootstrap age key
  # is generated on blushda, staged once at install via install-host.sh
  # extra-files, and stays put — it's the one out-of-band artifact per host.
  # See the SSH host certificates section of the README.
  age.identityPaths = [ "/etc/age/host.key" ];
}
