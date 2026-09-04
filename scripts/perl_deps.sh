#!/bin/sh
perldoc -t perllocal | grep '"Module"' | grep -Po '(\S+)$'
