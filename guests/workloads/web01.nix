# web01 — the nginx front end that replaces fw02's reverse proxy.
# Breed: guests/base.nix + this overlay. Flake attr `web01`
# (`incus-guest build --config web01` → image alias `nixos-web01`).
#
# Pure Nix, no Docker. Native services.nginx, one virtualHost per site that
# is live on fw02 today (vault: "web01 Host Build Plan"). Sites whose
# upstream is down or whose DNS no longer points at us stay broken and are
# deliberately NOT carried over: api/zul.bitrail.com, email.bonggpt.com,
# api/api-dev/jhu-api.zxdpn.net, demoweb/pypi.zxerex.net, zul.zxerex.com,
# zxerex.com.
#
# Network identity is NOT set here. Like every guest, hostname and the static
# address come from incus/cloud-init at launch (guests/base.nix). web01 is
# launched on infra100 at 172.16.0.240:
#
#   incus-guest build --config web01          # → alias nixos-web01
#   incus-launch web01 nixos-web01 --vm infra100:172.16.0.240 -- \
#     -p default -p cpu-4 -p mem-4GB -p storage-40GB \
#     -c security.secureboot=false
#
# (`-p default` supplies the eth0 that incus-launch re-points at infra100;
# storage-40GB then resizes the root disk. Gateway 172.16.0.254 and DNS
# 172.16.1.253 come from the NET_* table in scripts/incus-launch.sh.)
#
# Content: static roots live under /var/www/<site>. They are NOT in the
# store; content is copied in as a separate step (not managed here yet).
#
# TLS: every vhost uses NixOS ACME (HTTP-01 via the webroot nginx serves on
# :80). Until the router port-forward moves from fw02 to web01, issuance
# can't succeed and NixOS serves a self-signed placeholder cert per name;
# after cutover the real certs are issued on their own. No DNS-01, no
# Cloudflare token. Fallback (not active) per vhost: use the certs copied from
# fw02 — see `fw02Cert` below.

{ config, lib, pkgs, ... }:
let
  # Fallback only, not used by default. To serve a copied fw02 cert for a
  # name instead of ACME, replace `acme` with `fw02Cert "<name>"` in that
  # vhost. Files live outside the store, readable by nginx:
  #   /var/lib/web01-certs/<name>/fullchain.pem
  #   /var/lib/web01-certs/<name>/key.pem   (0640 root:nginx)
  # They never go in this repo.
  fw02Cert = name: {
    sslCertificate    = "/var/lib/web01-certs/${name}/fullchain.pem";
    sslCertificateKey = "/var/lib/web01-certs/${name}/key.pem";
  };
  acme = { enableACME = true; };

  # Common to every public vhost: HTTPS only (http → 301, except the ACME
  # challenge path, which NixOS keeps on :80).
  tls = { forceSSL = true; } // acme;

  # Static site rooted at /var/www/<dir>.
  static = dir: { root = "/var/www/${dir}"; };
in
{
  # No Docker on this breed (default-on for guests via guests/base.nix).
  my.services.docker.enable = false;

  # Accounts: admins (schwim) + Finn (sudo, via the catalog) + Ferb (no sudo).
  my.users.sets  = [ "admins" ];
  my.users.extra = [ "finn" "ferb" ];

  # Inbound: 80/443 only. SSH (22) is opened by the base sshd.
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  security.acme = {
    acceptTerms    = true;
    defaults.email = "schwim@bitrail.com";
  };

  # Fallback cert dir (empty unless the fw02 fallback is used).
  systemd.tmpfiles.rules = [
    "d /var/lib/web01-certs 0750 root nginx -"
    "d /var/www 0755 root root -"
  ];

  services.nginx = {
    enable = true;

    recommendedTlsSettings   = true;   # TLS 1.2/1.3 only, modern ciphers
    recommendedProxySettings = true;   # Host, X-Real-IP, X-Forwarded-* to upstreams
    recommendedOptimisation  = true;
    recommendedGzipSettings  = true;
    # No HSTS anywhere yet; add per vhost only on names we own outright.

    virtualHosts = {
      # Catch-all: unknown names get nothing. :443 refuses the TLS handshake
      # (no cert needed); :80 closes the connection.
      "_" = {
        default    = true;
        rejectSSL  = true;
        locations."/".return = "444";
      };

      # Static, plus /_dir/ (JSON listing of the root, used by index.html) and
      # the windbarb app's METAR/TAF proxy to aviationweather.gov.
      # The upstream URLs are inferred from the live responses (AWC data API
      # JSON); confirm against fw02 `nginx -T`. fw02 also proxies "mos";
      # its path isn't known yet, so it's not here.
      "sundries.bitrail.com" = tls // static "sundries" // {
        locations."/_dir/".extraConfig = ''
          alias /var/www/sundries/;
          autoindex on;
          autoindex_format json;
        '';
        locations."/windbarb/api/metar" = {
          proxyPass = "https://aviationweather.gov/api/data/metar";
          recommendedProxySettings = false;   # don't send our Host upstream
          extraConfig = ''
            proxy_set_header Host aviationweather.gov;
            proxy_ssl_server_name on;
          '';
        };
        locations."/windbarb/api/taf" = {
          proxyPass = "https://aviationweather.gov/api/data/taf";
          recommendedProxySettings = false;
          extraConfig = ''
            proxy_set_header Host aviationweather.gov;
            proxy_ssl_server_name on;
          '';
        };
      };

      # bitrail.com (+www) → sundries.
      "bitrail.com" = tls // {
        serverAliases = [ "www.bitrail.com" ];
        locations."/".return = "301 https://sundries.bitrail.com$request_uri";
      };

      "alyssadowdell.com" = tls // static "alyssadowdell.com" // {
        serverAliases = [ "www.alyssadowdell.com" ];
      };

      # SvelteKit-style static SPA.
      "adventure.bitrail.com" = tls // static "adventure_game";

      # Static SPA. fw02 also proxies part of this site to 172.16.254.93:8888;
      # which path isn't known yet (needs fw02 `nginx -T`), so it's not here.
      # Note 172.16.252.0/22 is routed via fw02's wg0 today.
      "allsky.spacepornobservatory.space" = tls // static "allsky";

      # Signal → Obsidian helper (vault: "obsid.7e7.co nginx").
      "obsid.7e7.co" = tls // {
        locations."= /".extraConfig = ''
          if ($arg_vault = "") {
            return 400 "missing vault";
          }
          return 308 "obsidian://open?$args";
        '';
      };

      # Zimbra webmail (cloud104). Upstream cert is not verified (nginx default).
      "email.bitrail.com" = tls // {
        locations."/".proxyPass = "https://172.16.4.105";
      };

      # Home Assistant. HA must list web01 (172.16.0.240) in trusted_proxies.
      "hass.bitrail.com" = tls // {
        locations."/" = {
          proxyPass       = "http://172.16.0.2:8123";
          proxyWebsockets = true;
        };
      };
    };
  };
}
