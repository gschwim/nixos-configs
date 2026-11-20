# 7e7.co contact-form backend for web01. Imported by ./web01.nix.
#
# Source: Ferb's 7e7-site repo at 006255d (deploy/contact-module.nix; the handler
# ./7e7-contact.py is backend/contact.py from the same commit, unmodified).
# The handler is Python 3 stdlib only; it listens on 127.0.0.1:8790 and nginx proxies
# https://www.7e7.co/api/contact to it (see nginx-web01.md).
#
# Mail: see "SMTP status" in nginx-web01.md.
# Zimbra accepts schwim@7e7.co (verified 2026-11-20); info@7e7.co is rejected 550 5.1.1 (no such recipient).
{ config, lib, pkgs, ... }:
let
  contactScript = pkgs.writeText "7e7-contact.py" (builtins.readFile ./7e7-contact.py);
in
{
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
      CONTACT_TRUST_PROXY = "1";        # client IP from nginx's X-Real-IP (loopback peer only)
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
}
