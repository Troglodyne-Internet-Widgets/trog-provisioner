require ["fileinto", "mailbox"];

# amavis marks mail that SpamAssassin scores as spam.  It goes to Junk Email
# before the sieve of the user runs, and :create makes Junk Email if it is not
# there yet.
if header :is "X-Spam-Flag" "YES" {
    fileinto :create "Junk Email";
    stop;
}
