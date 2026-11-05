# Installed in /etc/profile.d by Provisioner::Recipe::perl.  /opt/perl5/current
# is the perl that the last build made, so a rebuild needs no new file.
case ":$PATH:" in
    *:/opt/perl5/current/bin:*) ;;
    *) PATH="/opt/perl5/current/bin:$PATH" ;;
esac
