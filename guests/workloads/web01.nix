# web01 — the nginx front end that replaces fw02's reverse proxy.
# Breed: guests/base.nix + this overlay. Flake attr `web01`
# (`incus-guest build --config web01` → image alias `nixos-web01`).
#
# Pure Nix, no Docker. Native services.nginx, one virtualHost per site that
# is live on fw02 today. Each vhost mirrors fw02's /etc/nginx/sites-enabled
# file (snapshot 2026-11-20, staged at grokhq01:~finn/web01-staging/nginx)
# except TLS/cert config, which NixOS ACME replaces, and listen addresses
# (fw02 binds 172.16.1.110; web01 listens on all addresses).
# Sites whose upstream is down or whose DNS no longer points at us stay
# broken and are deliberately NOT carried over: api/zul.bitrail.com,
# email.bonggpt.com, api/api-dev/jhu-api.zxdpn.net, demoweb/pypi.zxerex.net,
# zul.zxerex.com, zxerex.com.
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
# Content: sundries, adventure_game, allsky live under /var/www/<dir>, NOT in
# the store and NOT in this repo. After launch, push them from the staged fw02 copy on grokhq01
# (Finn has sudo on web01):
#
#     SSH="ssh -i ~/.ssh/web01_deploy -o IdentitiesOnly=yes"
#     cd ~finn/web01-staging/www
#     rsync -a --delete --rsync-path="sudo rsync" --chown=root:root \
#       --chmod=D755,F644 -e "$SSH" sundries adventure_game allsky \
#       finn@172.16.0.240:/var/www/
#
#   alyssadowdell.com is NOT rsynced: it's built from gschwim/allys-website
#   (flake input `allys-website`, see flake.nix) and served from the store.
#   Update it: `nix flake update allys-website`, commit flake.lock, deploy.
#   A rebuilt guest loses its root disk, so re-run the rsync after any relaunch.
#
# Deploy config changes from a commit on grokhq01 (finn's web01_deploy key;
# wheel is a nix trusted-user below, so the closure copy is accepted):
#   NIX_SSHOPTS="-i ~/.ssh/web01_deploy -o IdentitiesOnly=yes" \
#     nixos-rebuild switch --flake .#web01 \
#     --target-host finn@172.16.0.240 --sudo
#
# TLS: every vhost uses NixOS ACME (HTTP-01 via the webroot nginx serves on
# :80) with forceSSL (http → 301 https, as fw02 does). Until the router
# port-forward moves from fw02 to web01, issuance can't succeed and NixOS
# serves a self-signed placeholder cert per name; after cutover the real
# certs are issued on their own. No DNS-01, no Cloudflare token.
# Fallback (not active) per vhost: certs copied from fw02 — see `fw02Cert`.

{ config, lib, pkgs, inputs, ... }:
let
  # alyssadowdell.com: only the site files (what its Dockerfile ships, plus
  # robots.txt/sitemap.xml) from the pinned allys-website input. .git,
  # Dockerfile and build files never reach the store path nginx serves.
  allysSite = pkgs.runCommand "alyssadowdell.com-site" { } ''
    src=${inputs.allys-website}
    mkdir -p $out
    cp $src/index.html $src/styles.css $src/robots.txt $src/sitemap.xml $out/
    cp -r $src/images $out/images
  '';

  # Fallback only, not used by default. To serve a copied fw02 cert for a
  # name instead of ACME, replace `acme` with `fw02Cert "<name>"` in `tls`
  # for that vhost. Files live outside the store, readable by nginx:
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
  # HTTP/1.1 only, as on fw02 (it never enabled http2).
  tls = { forceSSL = true; http2 = false; } // acme;

  # sundries windbarb API proxies (fw02: same block for metar/taf/mos).
  # fw02 used `resolver 127.0.0.1` (its local BIND); web01's local resolver is
  # systemd-resolved on 127.0.0.53.
  awc = kind: {
    extraConfig = ''
      resolver 127.0.0.53 valid=300s ipv6=off;
      proxy_pass https://aviationweather.gov/api/data/${kind}$is_args$args;
      proxy_ssl_server_name on;
      proxy_ssl_verify off;
      proxy_set_header Host aviationweather.gov;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
    '';
  };

  # adventure.bitrail.com security headers. On fw02 they sit at server level
  # only, so its two asset locations (which add Cache-Control) silently drop
  # them. NixOS's build-time nginx check (gixy) rejects that, so they're
  # repeated in those locations: assets now carry them too.
  secHeaders = ''
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";
  '';
in
{
  # Named instance: pin the hostname cloud-init gave it at launch, so a
  # nixos-rebuild switch doesn't revert it to the NixOS default ("nixos").
  networking.hostName = "web01";

  # fw02's zone; sundries /files/ listings use autoindex_localtime.
  time.timeZone = "America/Phoenix";

  # Let wheel (schwim, finn) push store paths for `nixos-rebuild
  # --target-host`. Wheel already has passwordless sudo, so this grants
  # nothing new.
  nix.settings.trusted-users = [ "root" "@wheel" ];

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

  systemd.tmpfiles.rules = [
    "d /var/lib/web01-certs 0750 root nginx -"   # fallback cert dir (empty unless used)
    "d /var/www 0755 root root -"
  ];

  services.nginx = {
    enable = true;

    # http{} level, matched to fw02's nginx.conf. TLS protocols/ciphers come
    # from recommendedTlsSettings (TLS 1.2/1.3) instead of fw02's certbot
    # options file. Proxy headers are written per location exactly as fw02
    # has them, so the NixOS proxy defaults are off.
    recommendedTlsSettings   = true;
    recommendedOptimisation  = true;    # sendfile, tcp_nopush/nodelay, keepalive 65
    recommendedProxySettings = false;
    recommendedGzipSettings  = false;
    clientMaxBodySize        = "1m";    # nginx default, as on fw02
    appendHttpConfig = ''
      gzip on;
    '';
    # No HSTS anywhere (fw02 has none).

    # allsky /live cache. fw02: proxy_cache_path /tmp/nginx levels=1:2
    # keys_zone=allsky:10m max_size=50m inactive=2m use_temp_path=off.
    # Path moves to /var/cache/nginx/allsky (nginx's writable cache dir here).
    proxyCachePath.allsky = {
      enable       = true;
      levels       = "1:2";
      keysZoneName = "allsky";
      keysZoneSize = "10m";
      maxSize      = "50m";
      inactive     = "2m";
      useTempPath  = false;
    };

    virtualHosts = {
      # Catch-all: unknown names get nothing. :443 refuses the TLS handshake
      # (no cert needed); :80 closes the connection. (fw02: 404 + self-signed.)
      "_" = {
        default   = true;
        rejectSSL = true;
        locations."/".return = "444";
      };

      # fw02: sites-available/games.bitrail.com.conf (enabled as sundries).
      "sundries.bitrail.com" = tls // {
        root = "/var/www/sundries";
        locations = {
          # Game discovery API: JSON listing of the web root.
          "^~ /_dir/".extraConfig = ''
            alias            /var/www/sundries/;
            autoindex        on;
            autoindex_format json;
            index            off;
          '';
          # File browser.
          "^~ /files/".extraConfig = ''
            alias                /var/www/sundries/files/;
            autoindex            on;
            autoindex_format     html;
            autoindex_exact_size off;
            autoindex_localtime  on;
            index                off;
          '';
          # Portal root — never cache.
          "= /".extraConfig = ''
            add_header Cache-Control "no-store, must-revalidate";
            try_files /index.html =404;
          '';
          # Regex locations match in file order on fw02; priorities keep it.
          # Per-game index.html + Flutter service worker — never cache.
          "~* (index\\.html|flutter_service_worker\\.js)$" = {
            priority    = 1001;
            extraConfig = ''
              add_header Cache-Control "no-store, must-revalidate";
            '';
          };
          # Fingerprinted Flutter assets — cache forever.
          "~* \\.(js|css|wasm|png|ico|ttf|woff2)$" = {
            priority    = 1002;
            extraConfig = ''
              add_header Cache-Control "public, max-age=31536000, immutable";
              gzip_static on;
            '';
          };
          # Per-game SPA routing: /<game>/anything → /<game>/index.html.
          "~ ^/([^/]+)" = {
            priority    = 1003;
            extraConfig = ''
              try_files $uri $uri/ /$1/index.html;
            '';
          };
          # METAR/TAF/MOS proxy — avoids browser CORS on aviationweather.gov.
          "^~ /windbarb/api/metar" = awc "metar";
          "^~ /windbarb/api/taf"   = awc "taf";
          "^~ /windbarb/api/mos"   = awc "mos";
        };
      };

      # bitrail.com (+www) → sundries.
      "bitrail.com" = tls // {
        serverAliases = [ "www.bitrail.com" ];
        locations."/".return = "301 https://sundries.bitrail.com$request_uri";
      };

      "alyssadowdell.com" = tls // {
        serverAliases = [ "www.alyssadowdell.com" ];
        root = "${allysSite}";
        extraConfig = ''
          index index.html;
        '';
        locations = {
          "/".tryFiles = "$uri $uri/ =404";
          "~* \\.(css|js|jpg|jpeg|png|svg|webp|ico)$".extraConfig = ''
            expires 7d;
            add_header Cache-Control "public";
          '';
          # Not on fw02 (it served .git). Block dotfiles; ACME's ^~ prefix
          # location still wins for /.well-known/acme-challenge/.
          "~ /\\." = {
            priority    = 999;
            extraConfig = ''
              deny all;
            '';
          };
        };
      };

      # SvelteKit static SPA.
      "adventure.bitrail.com" = tls // {
        root = "/var/www/adventure_game";
        extraConfig = ''
          index index.html;
          ${secHeaders}
          access_log /var/log/nginx/adventure.bitrail.com.access.log;
          error_log  /var/log/nginx/adventure.bitrail.com.error.log;
        '';
        locations = {
          "/".tryFiles = "$uri $uri/ /index.html";
          "~* \\.(?:jpg|jpeg|gif|png|ico|cur|gz|svg|svgz|mp4|ogg|ogv|webm|htc|woff|woff2|ttf|eot)$" = {
            priority    = 1001;
            extraConfig = ''
              expires 1y;
              access_log off;
              add_header Cache-Control "public";
              ${secHeaders}
            '';
          };
          "~* \\.(?:js|css)$" = {
            priority    = 1002;
            extraConfig = ''
              expires 1y;
              access_log off;
              add_header Cache-Control "public";
              ${secHeaders}
            '';
          };
          "~ /\\." = {
            priority    = 1003;
            extraConfig = ''
              deny all;
            '';
          };
        };
      };

      # Static SPA + /live proxy to the allsky camera. 172.16.254.93 sits in
      # 172.16.252.0/22, which fw02 routes over its wg0 today; web01 reaches it
      # only if the gateway routes that range.
      "allsky.spacepornobservatory.space" = tls // {
        extraConfig = ''
          client_max_body_size 2M;
        '';
        locations = {
          "/" = {
            root        = "/var/www/allsky";
            index       = "index.html";
          };
          "/live".extraConfig = ''
            proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_http_version      1.1;
            proxy_buffering         off;
            proxy_read_timeout      20m;
            proxy_pass              http://172.16.254.93:8888;
            proxy_cache             allsky;
          '';
        };
      };

      # Signal → Obsidian helper.
      "obsid.7e7.co" = tls // {
        locations."= /".extraConfig = ''
          if ($arg_vault = "") {
              return 400 "missing vault";
          }
          return 308 "obsidian://open?$args";
        '';
      };

      # Zimbra webmail (cloud104). fw02's :80 server only 301s to https, so
      # only the :443 proxy is mirrored. Upstream cert not verified (nginx default).
      "email.bitrail.com" = tls // {
        extraConfig = ''
          client_max_body_size 25M;
        '';
        locations."/".extraConfig = ''
          proxy_pass              https://172.16.4.105:443/;
          proxy_set_header        Host            $host;
          proxy_set_header        X-Real-IP       $remote_addr;
          proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_max_temp_file_size        0;
        '';
      };

      # Home Assistant. HA must list web01 (172.16.0.240) in trusted_proxies.
      "hass.bitrail.com" = tls // {
        extraConfig = ''
          client_max_body_size 0;
        '';
        locations."/".extraConfig = ''
          proxy_pass http://172.16.0.2:8123;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
        '';
      };
    };
  };
}
