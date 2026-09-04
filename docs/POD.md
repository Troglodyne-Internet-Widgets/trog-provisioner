# POD and perl module documentation guidelines

Generally for our perl modules we are OK with just having some minimal commentary above the subroutine,
though it is preferred to use perl POD when possible instead.

## Recommended Sections

- head1 with the name of the module.
- head2 SYNOPSIS with example usage.
- head2 DESCRIPTION that contains a human readable explanation of what this module does.
- head3 can be used for individual subroutines/methods but if we document them this way we need to also document INPUTS and OUTPUTS via indentation (=over 1, =item blahblah, =back).

Don't be wordy here. Where possible emulate the existing style in other modules. Ideally we convey what's needed/useful to users in the least words possible using imperative voice.
