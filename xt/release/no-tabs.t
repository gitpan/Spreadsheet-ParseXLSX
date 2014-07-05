use strict;
use warnings;

# this test was generated with Dist::Zilla::Plugin::Test::NoTabs 0.07

use Test::More 0.88;
use Test::NoTabs;

my @files = (
    'lib/Spreadsheet/ParseXLSX.pm',
    't/00-compile.t',
    't/basic.t',
    't/bug-10.t',
    't/bug-11.t',
    't/bug-12.t',
    't/bug-13.t',
    't/bug-14.t',
    't/bug-15.t',
    't/bug-2.t',
    't/bug-3.t',
    't/bug-4.t',
    't/bug-5.t',
    't/bug-6-2.t',
    't/bug-6.t',
    't/bug-7.t',
    't/bug-8.t',
    't/bug-lock.t',
    't/cell-to-row-col.t',
    't/column-formats.t',
    't/tab-color.t'
);

notabs_ok($_) foreach @files;
done_testing;
