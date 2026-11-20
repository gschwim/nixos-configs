# 7e7.co contact-form backend for web01. Imported by ./web01.nix.
#
# Source: Ferb's 7e7-site repo at f017700 (deploy/contact-module.nix; the handler
# ./7e7-contact.py is backend/contact.py from the same commit, unmodified).
# The handler is Python 3 stdlib only; it listens on 127.0.0.1:8790 and nginx proxies
# https://www.7e7.co/api/contact to it (see nginx-web01.md).
#
# Mail: see "SMTP status" in nginx-web01.md.
# Zimbra accepts schwim@7e7.co (verified 2026-11-20); info@7e7.co is rejected 550 5.1.1 (no such recipient).
{ config, lib, pkgs, ... }:
let
  cfg = config.my.services.e7contact;
  contactScript = pkgs.writeText "7e7-contact.py" (builtins.readFile ./7e7-contact.py);
in
{
  # Off by default: no unit exists until enabled, and nginx answers
  # /api/contact with 502. Turn on in web01.nix once the form JS is live:
  #   my.services.e7contact.enable = true;
  options.my.services.e7contact.enable =
    lib.mkEnableOption "7e7.co contact-form handler (127.0.0.1:8790)";

  config = lib.mkIf cfg.enable {
    systemd.services."7e7-contact" = {
      description = "7e7.co contact form handler";
      wantedBy = [ "multi-user.target" ];
      after    = [ "network-online.target" ];
      wants    = [ "network-online.target" ];

      environment = {
        CONTACT_LISTEN      = "127.0.0.1:8790";
        CONTACT_SMTP_HOST   = "smtp.bitrail.com";
        CONTACT_SMTP_PORT   = "25";
        # Zimbra's STARTTLS cert does not verify against the system CA bundle
        # ("unable to get local issuer certificate"), so encrypt without verifying.
        CONTACT_SMTP_TLS    = "opportunistic";
        CONTACT_MAIL_FROM   = "noreply@7e7.co";
        CONTACT_FROM_NAME   = "7e7 website";
        CONTACT_MAIL_TO     = "schwim@7e7.co";
        CONTACT_HELO        = "www.7e7.co";
        CONTACT_TRUST_PROXY = "1";        # client IP from nginx X-Real-IP / X-Forwarded-For (loopback peer only)
        CONTACT_MIN_SECONDS = "3";        # silent-drop submissions faster than this (fill-time token)
        CONTACT_RATE_PER_IP = "5";        # in-process backstop; nginx limit_req is burst 3 + 1r/m
        CONTACT_RATE_WINDOW = "3600";     # seconds (5 per hour)
        PYTHONUNBUFFERED    = "1";
        # Option: authenticated submission instead of port 25. Put the mailbox password in a
        # root-only file outside the store (from KeePass) and uncomment:
        # CONTACT_SMTP_PORT          = "587";
        # CONTACT_SMTP_TLS           = "verify";  # fix the server certificate chain first
        # CONTACT_SMTP_USER          = "noreply@7e7.co";
        # CONTACT_SMTP_PASSWORD_FILE = "%d/smtp-password";
      };

      serviceConfig = {
        ExecStart   = "${pkgs.python3}/bin/python3 -I ${contactScript}";
        DynamicUser = true;
        Restart     = "on-failure";
        RestartSec  = "2s";
        # LoadCredential = "smtp-password:/var/lib/7e7-contact/smtp-password";  # with the 587 option

        # Hardening
        NoNewPrivileges         = true;
        CapabilityBoundingSet   = "";
        AmbientCapabilities     = "";
        ProtectSystem           = "strict";
        ProtectHome             = true;
        PrivateTmp              = true;
        PrivateDevices          = true;
        PrivateUsers            = true;
        ProtectHostname         = true;
        ProtectClock            = true;
        ProtectKernelTunables   = true;
        ProtectKernelModules    = true;
        ProtectKernelLogs       = true;
        ProtectControlGroups    = true;
        ProtectProc             = "invisible";
        ProcSubset              = "pid";
        # AF_UNIX is needed for name lookups through nscd.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces      = true;
        RestrictRealtime        = true;
        RestrictSUIDSGID        = true;
        LockPersonality         = true;
        MemoryDenyWriteExecute  = true;
        RemoveIPC               = true;
        SystemCallArchitectures = "native";
        SystemCallFilter        = [ "@system-service" "~@privileged" "~@resources" ];
        UMask                   = "0077";
        MemoryMax               = "128M";
        TasksMax                = 64;
        # Optional egress pin: loopback plus the mail server only.
        # IPAddressDeny  = "any";
        # IPAddressAllow = [ "localhost" "184.183.25.50" ];
      };
    };
  };
}
