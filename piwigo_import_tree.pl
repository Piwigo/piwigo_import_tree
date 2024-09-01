#!/usr/bin/perl

# author: Pierrick Le Gall (plg)
# version: 1.0
# documentation: http://piwigo.org/doc/doku.php?id=user_documentation:tools:piwigo_import_tree
#
# usage:
# perl piwigo_import_tree.pl
#    --base_url=http://address/of/your/piwigo
#    --user=admin_username
#    --password=??
#    --directory="my photos directory"
#    [--parent_album_id=NN]
#    [--quiet]
#    [--only_write_cache]
#    [--reload_properties]
#    [--debug]
#    [--short_lines]

use strict;
use warnings;

# make it compatible with Windows, but breaks Linux
#use utf8;

use File::Find;
use Data::Dumper;
use File::Basename;
use LWP::UserAgent;
use JSON;
use Getopt::Long;
use Encode qw/is_utf8 decode/;
use Time::HiRes qw/gettimeofday tv_interval/;
use Digest::MD5 qw/md5 md5_hex/;

my %opt = ();
GetOptions(
    \%opt,
    qw/
          base_url=s
          username=s
          password=s
          directory=s
          parent_album_id=s
          define=s%
          quiet
          only_write_cache
          reload_properties
          debug
          short_lines
      /
);

my $album_dir = $opt{directory};
$album_dir =~ s{^\./*}{};

our $ua = LWP::UserAgent->new;
$ua->ssl_opts(
    SSL_verify_mode => 0,
    verify_hostname => 0
);
$ua->agent('Mozilla/piwigo_remote.pl 1.25');
$ua->cookie_jar({});

my %conf;
my %conf_default = (
    base_url => 'http://localhost/plg/piwigo/salon',
    username => 'plg',
    password => 'plg',
);

foreach my $conf_key (keys %conf_default) {
    $conf{$conf_key} = defined $opt{$conf_key} ? $opt{$conf_key} : $conf_default{$conf_key}
}

$ua->default_headers->authorization_basic(
    $conf{username},
    $conf{password}
);

my $result = undef;
my $query = undef;

binmode STDOUT, ":encoding(utf-8)";

# Login to Piwigo
piwigo_login();

# Fill an "album path to album id" cache
my %piwigo_albums = ();

my $response = $ua->post(
    $conf{base_url}.'/ws.php?format=json',
    {
        method => 'pwg.categories.getList',
        recursive => 1,
        fullname => 1,
    }
);

my $albums_aref = from_json($response->content)->{result}->{categories};
foreach my $album_href (@{$albums_aref}) {
    $piwigo_albums{ $album_href->{name} } = $album_href->{id};
}
# print Dumper(\%piwigo_albums)."\n\n";

if (defined $opt{parent_album_id}) {
    foreach my $album_path (keys %piwigo_albums) {
        if ($piwigo_albums{$album_path} == $opt{parent_album_id}) {
            $conf{parent_album_id} = $opt{parent_album_id};
            $conf{parent_album_path} = $album_path;
        }
    }

    if (not defined $conf{parent_album_path}) {
        print "Parent album ".$opt{parent_album_id}." does not exist\n";
        exit();
    }
}

# Initialize a cache with file names of existing photos, for related albums
my %photos_of_album = ();

# Synchronize local folder with remote Piwigo gallery
find({wanted => \&add_to_piwigo, no_chdir => 1}, $album_dir);

#---------------------------------------------------------------------
# Functions
#---------------------------------------------------------------------

sub piwigo_login {
    my $response = $ua->post(
        $conf{base_url}.'/ws.php?format=json',
        {
            method => 'pwg.session.login',
            username => $conf{username},
            password => $conf{password},
        }
    );

    # print Dumper($response);
}

sub fill_photos_of_album {
    my %params = @_;

    if (defined $photos_of_album{ $params{album_id} }) {
        return 1;
    }

    piwigo_login();
    my $response = $ua->post(
        $conf{base_url}.'/ws.php?format=json',
        {
            method => 'pwg.categories.getImages',
            cat_id => $params{album_id},
            per_page => 1000000,
        }
    );

    foreach my $image_href (@{from_json($response->content)->{result}{images}}) {
        $photos_of_album{ $params{album_id} }{ $image_href->{file} } = $image_href->{id};
    }
}

sub photo_exists {
    my %params = @_;

    fill_photos_of_album(album_id => $params{album_id});

    if (defined $photos_of_album{ $params{album_id} }{ $params{file} }) {
    	return $photos_of_album{ $params{album_id} }{ $params{file} };
    }
    else {
    	return 0;
    }
}

sub add_album {
    my %params = @_;

    my $form = {
        method => 'pwg.categories.add',
        name => $params{name},
    };

    if (defined $params{parent}) {
    	$form->{parent} = $params{parent};
    }

    piwigo_login();
    my $response = $ua->post(
        $conf{base_url}.'/ws.php?format=json',
        $form
    );

    return from_json($response->content)->{result}{id};
}

sub set_album_properties {
    my %params = @_;

    print '[set_album_properties] for directory "'.$params{dir}.'"'."\n" if $opt{debug};

    # avoid to load the readme.txt file 10 times if an album has 10
    # sub-albums
    our %set_album_properties_done;
    if (defined $set_album_properties_done{ $params{id} }) {
        print '[set_album_properties] already done'."\n" if $opt{debug};
        return;
    }
    $set_album_properties_done{ $params{id} } = 1;

    $params{dir} =~ s{ / }{/}g;

    # is there a file "readme.txt" in the directory of the album?
    my $desc_filepath = $params{dir}.'/readme.txt';

    if (not -f $desc_filepath) {
        print "no readme.txt for ".$params{dir}."\n" if $opt{debug};
        return;
    }

    # example of readme.txt:
    #
    # Title: First public opening
    # Date: 2009-09-26
    # Copyright: John Connor
    # 
    # Details:
    # The first day Croome Court is opened to the public by the National Trust.
    # And here is another line for details!

    open(IN, '<', $desc_filepath);
    my $title = undef;
    my $date_string = undef;
    my $copyright = undef;
    my $is_details = 0;
    my $details = '';
    while (my $desc_line = <IN>) {
        chomp($desc_line);

        if ($is_details) {
            $details.= $desc_line;
        }
        elsif ($desc_line =~ /^Date:\s*(.*)$/) {
            $date_string = $1;
        }
        elsif ($desc_line =~ /^Title:\s*(.*)$/) {
            $title = $1;
        }
        elsif ($desc_line =~ /^Copyright:\s*(.*)$/) {
            $copyright = $1;
        }
        elsif ($desc_line =~ /^Details:/) {
            # from now, all the remaining lines are "details"
            $is_details = 1;
        }
    }
    close(IN);

    if (defined $date_string or $details ne '') {
        my $comment = '';

        if (defined $date_string) {
            $comment.= '<span class="albumDate">'.$date_string.'</span><br>';
        }
        if (defined $copyright) {
            $comment.= '<span class="albumCopyright">'.$copyright.'</span><br>';
        }
        $comment.= $details;

        my $form = {
            method => 'pwg.categories.setInfo',
            category_id => $params{id},
            comment => $comment,
        };

        if (defined $title) {
            $form->{name} = $title;
        }

        piwigo_login();

        my $response = $ua->post(
            $conf{base_url}.'/ws.php?format=json',
            $form
        );
    }
}

sub set_photo_properties {
    my %params = @_;

    print '[set_photo_properties] for "'.$params{path}.'"'."\n" if $opt{debug};

    # is there any title defined in a descript.ion file?
    my $desc_filepath = dirname($params{path}).'/descript.ion';

    if (not -f $desc_filepath) {
        print '[set_photo_properties] no descript.ion file'."\n" if $opt{debug};
        return;
    }

    my $property = undef;
    my $photo_filename = basename($params{path});
    open(IN, '<', $desc_filepath);
    while (my $desc_line = <IN>) {
        if ($desc_line =~ /^$photo_filename/) {
            chomp($desc_line);
            $property = (split /\t/, $desc_line, 2)[1];
        }
    }
    close(IN);

    if (defined $property and $property ne '') {
        print '[photo '.$params{id}.'] "';

        if (defined $opt{short_lines}) {
            print basename($params{path});
        }
        else {
            print $params{path};
        }

        print '", set photo description "'.$property.'"'."\n";

        my $form = {
            method => 'pwg.images.setInfo',
            image_id => $params{id},
            single_value_mode => 'replace',
            comment => $property,
        };

        piwigo_login();

        my $response = $ua->post(
            $conf{base_url}.'/ws.php?format=json',
            $form
        );
    }
}

sub add_photo {
    my %params = @_;

    my $form = {
        method => 'pwg.images.addSimple',
        image => [$params{path}],
        category => $params{album_id},
    };

    print '[album '.$params{album_id}.'] "';
    if (defined $opt{short_lines}) {
        print basename($params{path});
    }
    else {
        print $params{path};
    }
    print '" upload starts... ';

    $| = 1;
    my $t1 = [gettimeofday];

    piwigo_login();
    my $response = $ua->post(
        $conf{base_url}.'/ws.php?format=json',
        $form,
        'Content_Type' => 'form-data',
    );

    my $photo_id = from_json($response->content)->{result}{image_id};

    my $elapsed = tv_interval($t1);
    print ' completed ('.sprintf('%u ms', $elapsed * 1000).', photo '.$photo_id.')'."\n";

    return $photo_id;
}

sub add_to_piwigo {
    # print $File::Find::name."\n";
    my $path = $File::Find::name;
    my $parent_dir = dirname($album_dir);
    if ($parent_dir ne '.') {
        # print '$parent_dir = '.$parent_dir."\n";
        $path =~ s{^$parent_dir/}{};
    }
    # print $path."\n";

    if (-d) {
    	my $up_dir = '';
    	my $parent_id = undef;

    	if (defined $conf{parent_album_path}) {
            $up_dir = $conf{parent_album_path}.' / ';
            $parent_id = $conf{parent_album_id};
    	}

    	foreach my $dir (split '/', $path) {
            my $is_new_album = 0;

            if (not defined $piwigo_albums{$up_dir.$dir}) {
                my $id = cached_album(dir => $up_dir.$dir);
                # if the album is not in the cache OR if the id in the cache
                # matches no album fetched by pwg.categories.getList, then
                # we have to create the album first
                if (not defined $id or not grep($_ eq $id, values(%piwigo_albums))) {
                    print 'album "'.$up_dir.$dir.'" must be created'."\n";
                    $is_new_album = 1;
                    $id = add_album(name => $dir, parent => $parent_id);
                    cache_add_album(dir => $up_dir.$dir, id => $id);
                }
                $piwigo_albums{$up_dir.$dir} = $id;
            }

            if ($is_new_album or defined $opt{reload_properties}) {
                set_album_properties(dir => $up_dir.$dir, id => $piwigo_albums{$up_dir.$dir});
            }

            $parent_id = $piwigo_albums{$up_dir.$dir};
            $up_dir.= $dir.' / ';
    	}
    }

    if (-f and $path =~ /\.(jpe?g|gif|png)$/i) {
    	my $album_key = join(' / ', split('/', dirname($path)));

    	if (defined $conf{parent_album_path}) {
            $album_key = $conf{parent_album_path}.' / '.$album_key;
    	}

        my $album_id = $piwigo_albums{$album_key};

        my $image_id = photo_exists(album_id => $album_id, file => basename($File::Find::name));
        if (not defined $image_id or $image_id < 1) {
            $image_id = cached_photo(path => $File::Find::name, dir => $album_key);
        }

        if (defined $image_id and $image_id >= 1) {
            if (not $opt{quiet}) {
                print $File::Find::name.' already exists in Piwigo, skipped'."\n";
            }

            if (defined $opt{reload_properties}) {
                set_photo_properties(path => $File::Find::name, id => $image_id);
            }

            return 1;
        }

        $image_id = add_photo(path => $File::Find::name, album_id => $album_id);
        set_photo_properties(path => $File::Find::name, id => $image_id);
        cache_add_photo(path => $File::Find::name, dir => $album_key, id => $image_id);
    }
}

sub cache_add_photo {
    my %params = @_;

    if (cached_photo(path => $params{path}, dir => $params{dir})) {
        if (not $opt{quiet}) {
            print 'photo is in the cache, no upload'."\n";
        }
        return 1;
    }

    $params{dir} =~ s{ / }{/}g;

    my $filepath = $params{dir}.'/.piwigo_import_tree.txt';

    open(my $ofh, '>> '.$filepath) or die 'cannot open file "'.$filepath.'" for writing';
    print {$ofh} $conf{base_url}.' '.md5_hex(basename($params{path}));

    if (defined $params{id}) {
        print {$ofh} ' [id='.$params{id}.']';
    }

    print {$ofh} "\n";
    close($ofh);
}

sub cached_photo {
    my %params = @_;

    $params{dir} =~ s{ / }{/}g;

    my $filepath = $params{dir}.'/.piwigo_import_tree.txt';

    if (not -f $filepath) {
        return undef;
    }

    my $photo_id = undef;
    my $photo_filename_md5 = md5_hex(basename($params{path}));

    open(my $ifh, '<'.$filepath) or die 'cannot open file "'.$filepath.'" for reading';
    while (my $line = <$ifh>) {
        chomp $line;
        if ($line =~ m/$photo_filename_md5/) {
            # TODO if needed : search the [id=(\d+)] for photo_id
            if ($line =~ m/\[id=(\d+)\]/) {
                return $1;
            }
            else {
                return -1; # true, but not an image_id
            }
        }
    }
    close($ifh);

    return undef;
}

sub cache_add_album {
    my %params = @_;

    $params{dir} =~ s{ / }{/}g;

    my $filepath = $params{dir}.'/.piwigo_import_tree.txt';

    open(my $ofh, '>> '.$filepath) or die 'cannot open file "'.$filepath.'" for writing';
    print {$ofh} $conf{base_url}.' album_id = '.$params{id}."\n";
    print $conf{base_url}.' album_id = '.$params{id}."\n";
    close($ofh);
}

sub cached_album {
    my %params = @_;

    $params{dir} =~ s{ / }{/}g;

    my $filepath = $params{dir}.'/.piwigo_import_tree.txt';

    if (not -f $filepath) {
        return undef;
    }

    my $album_id = undef;

    open(my $ifh, '<'.$filepath) or die 'cannot open file "'.$filepath.'" for reading';
    while (my $line = <$ifh>) {
        chomp $line;
        if ($line =~ m/album_id = (\d+)/) {
            $album_id = $1;
        }
    }
    close($ifh);

    print 'directory "'.$params{dir}.'" was found as album '.$album_id."\n";

    return $album_id;
}
