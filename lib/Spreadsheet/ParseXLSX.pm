package Spreadsheet::ParseXLSX;
BEGIN {
  $Spreadsheet::ParseXLSX::AUTHORITY = 'cpan:DOY';
}
{
  $Spreadsheet::ParseXLSX::VERSION = '0.05';
}
use strict;
use warnings;
# ABSTRACT: parse XLSX files

use Archive::Zip;
use Graphics::ColorUtils 'rgb2hls', 'hls2rgb';
use Scalar::Util 'openhandle';
use Spreadsheet::ParseExcel;
use XML::Twig;



sub new {
    bless {}, shift;
}


sub parse {
    my $self = shift;
    my ($file) = @_;

    my $zip = Archive::Zip->new;
    if (openhandle($file)) {
        bless $file, 'IO::File' if ref($file) eq 'GLOB'; # sigh
        $zip->readFromFileHandle($file) == Archive::Zip::AZ_OK
            or die "Can't open filehandle as a zip file";
    }
    elsif (!ref($file)) {
        $zip->read($file) == Archive::Zip::AZ_OK
            or die "Can't open file '$file' as a zip file";
    }
    else {
        die "Argument to 'new' must be a filename or open filehandle";
    }

    return $self->_parse_workbook($zip);
}

sub _parse_workbook {
    my $self = shift;
    my ($zip) = @_;

    my $files = $self->_extract_files($zip);

    my $workbook = Spreadsheet::ParseExcel::Workbook->new;

    my ($version)    = $files->{workbook}->find_nodes('//fileVersion');
    my ($properties) = $files->{workbook}->find_nodes('//workbookPr');

    $workbook->{Version} = $version->att('appName')
                         . ($version->att('lowestEdited')
                             ? ('-' . $version->att('lowestEdited'))
                             : (""));

    $workbook->{Flag1904} = $properties->att('date1904') ? 1 : 0;

    $workbook->{FmtClass} = Spreadsheet::ParseExcel::FmtDefault->new; # XXX

    my $themes = $self->_parse_themes((values %{ $files->{themes} })[0]); # XXX

    $workbook->{Color} = $themes->{Color};

    my $styles = $self->_parse_styles($workbook, $files->{styles});

    $workbook->{Format}    = $styles->{Format};
    $workbook->{FormatStr} = $styles->{FormatStr};
    $workbook->{Font}      = $styles->{Font};

    $workbook->{PkgStr} = $self->_parse_shared_strings($files->{strings});

    # $workbook->{StandardWidth} = ...;

    # $workbook->{Author} = ...;

    # $workbook->{PrintArea} = ...;
    # $workbook->{PrintTitle} = ...;

    my @sheets = map {
        my $idx = $_->att('r:id');
        my $sheet = Spreadsheet::ParseExcel::Worksheet->new(
            Name     => $_->att('name'),
            _Book    => $workbook,
            _SheetNo => $idx,
        );
        $self->_parse_sheet($sheet, $files->{sheets}{$idx});
        $sheet
    } $files->{workbook}->find_nodes('//sheets/sheet');

    $workbook->{Worksheet}  = \@sheets;
    $workbook->{SheetCount} = scalar(@sheets);

    my ($node) = $files->{workbook}->find_nodes('//workbookView');
    my $selected = $node->att('activeTab');
    $workbook->{SelectedSheet} = defined($selected) ? 0+$selected : 0;

    return $workbook;
}

sub _parse_sheet {
    my $self = shift;
    my ($sheet, $sheet_xml) = @_;

    # XXX need a fallback here, the dimension tag is optional
    my ($dimension) = $sheet_xml->find_nodes('//dimension');
    my ($rmin, $cmin, $rmax, $cmax) = $self->_dimensions(
        $dimension->att('ref')
    );

    $sheet->{MinRow} = $rmin;
    $sheet->{MinCol} = $cmin;
    $sheet->{MaxRow} = $rmax;
    $sheet->{MaxCol} = $cmax;

    for my $cell ($sheet_xml->find_nodes('//sheetData/row/c')) {
        my ($row, $col) = $self->_cell_to_row_col($cell->att('r'));
        my $val = $cell->first_child('v')
            ? $cell->first_child('v')->text
            : undef;
        my $type = $cell->att('t') || 'n';

        my $long_type;
        if (!defined($val)) {
            $long_type = 'Text';
            $val = '';
        }
        elsif ($type eq 's') {
            $long_type = 'Text';
            $val = $sheet->{_Book}{PkgStr}[$val]{Text};
        }
        elsif ($type eq 'n') {
            $long_type = 'Numeric';
            $val = defined($val) ? 0+$val : undef;
        }
        elsif ($type eq 'd') {
            $long_type = 'Date';
        }
        else {
            die "unimplemented type $type"; # XXX
        }

        my $format_idx = $cell->att('s') || 0;
        my $format = $sheet->{_Book}{Format}[$format_idx];

        # see the list of built-in formats below in _parse_styles
        # XXX probably should figure this out from the actual format string,
        # but that's not entirely trivial
        if (grep { $format->{FmtIdx} == $_ } 14..22, 45..47) {
            $long_type = 'Date';
        }

        my $cell = Spreadsheet::ParseExcel::Cell->new(
            Val      => $val,
            Type     => $long_type,
            Format   => $format,
            FormatNo => $format_idx,
            ($cell->first_child('f')
                ? (Formula => $cell->first_child('f')->text)
                : ()),
        );
        $cell->{_Value} = $sheet->{_Book}{FmtClass}->ValFmt(
            $cell, $sheet->{_Book}
        );
        $sheet->{Cells}[$row][$col] = $cell;
    }

    my @column_widths;
    my @row_heights;

    my ($format) = $sheet_xml->find_nodes('//sheetFormatPr');
    my $default_row_height = $format->att('defaultRowHeight') || 15;
    my $default_column_width = $format->att('baseColWidth') || 10;

    for my $col ($sheet_xml->find_nodes('//col')) {
        my $width = $col->att('width');
        $column_widths[$_ - 1] = $width
            for $col->att('min')..$col->att('max');
    }

    for my $row ($sheet_xml->find_nodes('//row')) {
        $row_heights[$row->att('r') - 1] = $row->att('ht');
    }

    $sheet->{DefRowHeight} = 0+$default_row_height;
    $sheet->{DefColWidth} = 0+$default_column_width;
    $sheet->{RowHeight} = [
        map { defined $_ ? 0+$_ : 0+$default_row_height } @row_heights
    ];
    $sheet->{ColWidth} = [
        map { defined $_ ? 0+$_ : 0+$default_column_width } @column_widths
    ];

    my ($selection) = $sheet_xml->find_nodes('//selection');
    if ($selection) {
        my $cell = $selection->att('activeCell');
        $sheet->{Selection} = [ $self->_cell_to_row_col($cell) ];
    }
    else {
        $sheet->{Selection} = [ 0, 0 ];
    }
}

sub _parse_shared_strings {
    my $self = shift;
    my ($strings) = @_;

    return [
        map {
            { Text => $_->text } # XXX are Unicode, Rich, or Ext important?
        } $strings->find_nodes('//t')
    ];
}

sub _parse_themes {
    my $self = shift;
    my ($themes) = @_;

    return {} unless $themes;

    my @color = map {
        $_->name eq 'a:sysClr' ? $_->att('lastClr') : $_->att('val')
    } $themes->find_nodes('//a:clrScheme/*/*');

    # this shouldn't be necessary, but the documentation is wrong here
    # see http://stackoverflow.com/questions/2760976/theme-confusion-in-spreadsheetml
    ($color[0], $color[1]) = ($color[1], $color[0]);
    ($color[2], $color[3]) = ($color[3], $color[2]);

    return {
        Color => \@color,
    }
}

sub _parse_styles {
    my $self = shift;
    my ($workbook, $styles) = @_;

    my %halign = (
        center           => 2,
        centerContinuous => 6,
        distributed      => 7,
        fill             => 4,
        general          => 0,
        justify          => 5,
        left             => 1,
        right            => 3,
    );

    my %valign = (
        bottom      => 2,
        center      => 1,
        distributed => 4,
        justify     => 3,
        top         => 0,
    );

    my %border = (
        dashDot          => 9,
        dashDotDot       => 11,
        dashed           => 3,
        dotted           => 4,
        double           => 6,
        hair             => 7,
        medium           => 2,
        mediumDashDot    => 10,
        mediumDashDotDot => 12,
        mediumDashed     => 8,
        none             => 0,
        slantDashDot     => 13,
        thick            => 5,
        thin             => 1,
    );

    my %fill = (
        darkDown        => 7,
        darkGray        => 3,
        darkGrid        => 9,
        darkHorizontal  => 5,
        darkTrellis     => 10,
        darkUp          => 8,
        darkVertical    => 6,
        gray0625        => 18,
        gray125         => 17,
        lightDown       => 13,
        lightGray       => 4,
        lightGrid       => 15,
        lightHorizontal => 11,
        lightTrellis    => 16,
        lightUp         => 14,
        lightVertical   => 12,
        mediumGray      => 2,
        none            => 0,
        solid           => 1,
    );

    my @fills = map {
        [
            $fill{$_->att('patternType')},
            $self->_color($workbook->{Color}, $_->first_child('fgColor')),
            $self->_color($workbook->{Color}, $_->first_child('bgColor')),
        ]
    } $styles->find_nodes('//fills/fill/patternFill');

    my @borders = map {
        my $border = $_;
        # XXX specs say "begin" and "end" rather than "left" and "right",
        # but... that's not what seems to be in the file itself (sigh)
        {
            colors => [
                map {
                    $self->_color(
                        $workbook->{Color},
                        $border->first_child($_)->first_child('color')
                    )
                } qw(left right top bottom)
            ],
            styles => [
                map {
                    $border{$border->first_child($_)->att('style') || 'none'}
                } qw(left right top bottom)
            ],
            diagonal => [
                0, # XXX ->att('diagonalDown') and ->att('diagonalUp')
                0, # XXX ->att('style')
                $self->_color(
                    $workbook->{Color},
                    $border->first_child('diagonal')->first_child('color')
                ),
            ],
        }
    } $styles->find_nodes('//borders/border');

    # these defaults are from
    # http://social.msdn.microsoft.com/Forums/en-US/oxmlsdk/thread/e27aaf16-b900-4654-8210-83c5774a179c
    my %format_str = (
        0  => 'GENERAL',
        1  => '0',
        2  => '0.00',
        3  => '#,##0',
        4  => '#,##0.00',
        5  => '$#,##0_);($#,##0)',
        6  => '$#,##0_);[Red]($#,##0)',
        7  => '$#,##0.00_);($#,##0.00)',
        8  => '$#,##0.00_);[Red]($#,##0.00)',
        9  => '0%',
        10 => '0.00%',
        11 => '0.00E+00',
        12 => '# ?/?',
        13 => '# ??/??',
        14 => 'm/d/yyyy',
        15 => 'd-mmm-yy',
        16 => 'd-mmm',
        17 => 'mmm-yy',
        18 => 'h:mm AM/PM',
        19 => 'h:mm:ss AM/PM',
        20 => 'h:mm',
        21 => 'h:mm:ss',
        22 => 'm/d/yyyy h:mm',
        37 => '#,##0_);(#,##0)',
        38 => '#,##0_);[Red](#,##0)',
        39 => '#,##0.00_);(#,##0.00)',
        40 => '#,##0.00_);[Red](#,##0.00)',
        45 => 'mm:ss',
        46 => '[h]:mm:ss',
        47 => 'mm:ss.0',
        48 => '##0.0E+0',
        49 => '@',
        (map {
            $_->att('numFmtId') => $_->att('formatCode')
        } $styles->find_nodes('//numFmts/numFmt')),
    );

    my @font = map {
        Spreadsheet::ParseExcel::Font->new(
            Height         => 0+$_->first_child('sz')->att('val'),
            # Attr           => $iAttr,
            # XXX not sure if there's a better way to keep the indexing stuff
            # intact rather than just going straight to #xxxxxx
            # XXX also not sure what it means for the color tag to be missing,
            # just assuming black for now
            Color          => ($_->first_child('color')
                ? $self->_color(
                    $workbook->{Color},
                    $_->first_child('color')
                )
                : '#000000'
            ),
            # Super          => $iSuper,
            # UnderlineStyle => $iUnderline,
            Name           => $_->first_child('name')->att('val'),

            Bold      => $_->has_child('b') ? 1 : 0,
            Italic    => $_->has_child('i') ? 1 : 0,
            # Underline => $bUnderline,
            # Strikeout => $bStrikeout,
        )
    } $styles->find_nodes('//fonts/font');

    my @format = map {
        my $alignment = $_->first_child('alignment');
        Spreadsheet::ParseExcel::Format->new(
            IgnoreFont         => !$_->att('applyFont'),
            IgnoreFill         => !$_->att('applyFill'),
            IgnoreBorder       => !$_->att('applyBorder'),
            IgnoreAlignment    => !$_->att('applyAlignment'),
            IgnoreNumberFormat => !$_->att('applyNumberFormat'),

            FontNo => 0+$_->att('fontId'),
            Font   => $font[$_->att('fontId')],
            FmtIdx => 0+$_->att('numFmtId'),

            # Lock     => $iLock,
            # Hidden   => $iHidden,
            # Style    => $iStyle,
            # Key123   => $i123,
            AlignH => $alignment
                ? $halign{$alignment->att('horizontal') || 'general'}
                : 0,
            Wrap => $alignment
                ? $alignment->att('wrapText')
                : 0,
            AlignV => $alignment
                ? $valign{$alignment->att('vertical') || 'bottom'}
                : 2,
            # JustLast => $iJustL,
            # Rotate   => $iRotate,

            # Indent  => $iInd,
            # Shrink  => $iShrink,
            # Merge   => $iMerge,
            # ReadDir => $iReadDir,

            BdrStyle => $borders[$_->att('borderId')]{styles},
            BdrColor => $borders[$_->att('borderId')]{colors},
            BdrDiag  => $borders[$_->att('borderId')]{diagonal},
            Fill     => $fills[$_->att('fillId')],
        )
    } $styles->find_nodes('//cellXfs/xf');

    return {
        FormatStr => \%format_str,
        Font      => \@font,
        Format    => \@format,
    }
}

sub _extract_files {
    my $self = shift;
    my ($zip) = @_;

    my $type_base =
        'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

    my $rels = $self->_parse_xml(
        $zip,
        $self->_rels_for('')
    );
    my $wb_name = ($rels->find_nodes(
        qq<//Relationship[\@Type="$type_base/officeDocument"]>
    ))[0]->att('Target');
    my $wb_xml = $self->_parse_xml($zip, $wb_name);

    my $path_base = $self->_base_path_for($wb_name);
    my $wb_rels = $self->_parse_xml(
        $zip,
        $self->_rels_for($wb_name)
    );
    my $strings_xml = $self->_parse_xml(
        $zip,
        $path_base . ($wb_rels->find_nodes(
            qq<//Relationship[\@Type="$type_base/sharedStrings"]>
        ))[0]->att('Target')
    );
    my $styles_xml = $self->_parse_xml(
        $zip,
        $path_base . ($wb_rels->find_nodes(
            qq<//Relationship[\@Type="$type_base/styles"]>
        ))[0]->att('Target')
    );

    my %worksheet_xml = map {
        $_->att('Id') => $self->_parse_xml($zip, $path_base . $_->att('Target'))
    } $wb_rels->find_nodes(qq<//Relationship[\@Type="$type_base/worksheet"]>);

    my %themes_xml = map {
        $_->att('Id') => $self->_parse_xml($zip, $path_base . $_->att('Target'))
    } $wb_rels->find_nodes(qq<//Relationship[\@Type="$type_base/theme"]>);

    return {
        workbook => $wb_xml,
        strings  => $strings_xml,
        styles   => $styles_xml,
        sheets   => \%worksheet_xml,
        themes   => \%themes_xml,
    };
}

sub _parse_xml {
    my $self = shift;
    my ($zip, $subfile) = @_;

    my $member = $zip->memberNamed($subfile);
    die "no subfile named $subfile" unless $member;

    my $xml = XML::Twig->new;
    $xml->parse($member->contents);

    return $xml;
}

sub _rels_for {
    my $self = shift;
    my ($file) = @_;

    my @path = split '/', $file;
    my $name = pop @path;
    $name = '' unless defined $name;
    push @path, '_rels';
    push @path, "$name.rels";

    return join '/', @path;
}

sub _base_path_for {
    my $self = shift;
    my ($file) = @_;

    my @path = split '/', $file;
    pop @path;

    return join('/', @path) . '/';
}

sub _dimensions {
    my $self = shift;
    my ($dim) = @_;

    my ($topleft, $bottomright) = split ':', $dim;
    $bottomright = $topleft unless defined $bottomright;

    my ($rmin, $cmin) = $self->_cell_to_row_col($topleft);
    my ($rmax, $cmax) = $self->_cell_to_row_col($bottomright);

    return ($rmin, $cmin, $rmax, $cmax);
}

sub _cell_to_row_col {
    my $self = shift;
    my ($cell) = @_;

    my ($col, $row) = $cell =~ /([A-Z]+)([0-9]+)/;

    (my $ncol = $col) =~ tr/A-Z/1-9A-Q/;
    $ncol = POSIX::strtol($ncol, 27);
    $ncol -= 1;

    my $nrow = $row - 1;

    return ($nrow, $ncol);
}

sub _color {
    my $self = shift;
    my ($colors, $color_node) = @_;

    my $color; # XXX
    if ($color_node) {
        $color = '#000000' # XXX
            if $color_node->att('auto');
        $color = '#' . Spreadsheet::ParseExcel->ColorIdxToRGB( # XXX
            $color_node->att('indexed')
        ) if defined $color_node->att('indexed');
        $color = '#' . substr($color_node->att('rgb'), 2, 6)
            if defined $color_node->att('rgb');
        $color = '#' . $colors->[$color_node->att('theme')]
            if defined $color_node->att('theme');

        $color = $self->_apply_tint($color, $color_node->att('tint'))
            if $color_node->att('tint');
    }

    return $color;
}

sub _apply_tint {
    my $self = shift;
    my ($color, $tint) = @_;

    my ($r, $g, $b) = map { oct("0x$_") } $color =~ /#(..)(..)(..)/;
    my ($h, $l, $s) = rgb2hls($r, $g, $b);

    if ($tint < 0) {
        $l = $l * (1.0 + $tint);
    }
    else {
        $l = $l * (1.0 - $tint) + (1.0 - 1.0 * (1.0 - $tint));
    }

    return scalar hls2rgb($h, $l, $s);
}


1;

__END__

=pod

=head1 NAME

Spreadsheet::ParseXLSX - parse XLSX files

=head1 VERSION

version 0.05

=head1 SYNOPSIS

  use Spreadsheet::ParseXLSX;

  my $parser = Spreadsheet::ParseXLSX->new;
  my $workbook = $parser->parse("file.xlsx");
  # see Spreadsheet::ParseExcel for further documentation

=head1 DESCRIPTION

This module is an adaptor for L<Spreadsheet::ParseExcel> that reads XLSX files.

=head1 METHODS

=head2 new

Returns a new parser instance. Takes no parameters.

=head2 parse($file)

Parses an XLSX file. Parsing errors throw an exception. C<$file> can be either
a filename or an open filehandle. Returns a
L<Spreadsheet::ParseExcel::Workbook> instance containing the parsed data.

=head1 BUGS

No known bugs.

Please report any bugs to GitHub Issues at
L<https://github.com/doy/spreadsheet-parsexlsx/issues>.

=head1 SEE ALSO

L<Spreadsheet::ParseExcel>: The equivalent, for XLS files.

L<Spreadsheet::XLSX>: An older, less robust and featureful implementation.

=head1 SUPPORT

You can find this documentation for this module with the perldoc command.

    perldoc Spreadsheet::ParseXLSX

You can also look for information at:

=over 4

=item * MetaCPAN

L<https://metacpan.org/release/Spreadsheet-ParseXLSX>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Spreadsheet-ParseXLSX>

=item * Github

L<https://github.com/doy/spreadsheet-parsexlsx>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Spreadsheet-ParseXLSX>

=back

=head1 SPONSORS

Parts of this code were paid for by

=over 4

=item Socialflow L<http://socialflow.com>

=back

=head1 AUTHOR

Jesse Luehrs <doy@tozt.net>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2013 by Jesse Luehrs.

This is free software, licensed under:

  The MIT (X11) License

=cut
