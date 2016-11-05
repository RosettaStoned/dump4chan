# dump4chan
Simple perl script used to dump files from 4chan posts

Dependencies

    Debian/Ubuntu

        sudo apt-get install libanyevent-perl libanyevent-http-perl

Example

    perl -w dump4chan.pl -d <dir> -b <regexp>

    perl -w dump4chan.pl -d . -b '^g$'


