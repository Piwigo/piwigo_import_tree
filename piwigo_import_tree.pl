#!/usr/bin/perl

# usage:
# perl piwigo_import_tree.pl --directory=/Users/pierrick/piwigo/album1

use strict;
use warnings;

use File::Find;
use Data::Dumper;
use File::Basename;
use LWP::UserAgent;
use JSON;
use Getopt::Long;
use Encode qw/is_utf8 decode/;

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
      /
);

my $album_dir = $opt{directory};
$album_dir =~ s{^\./*}{};

our $ua = LWP::UserAgent->new;
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
my $form = {
    method => 'pwg.session.login',
    username => $conf{username},
    password => $conf{password},
};

$result = $ua->post(
    $conf{base_url}.'/ws.php?format=json',
    $form
);

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

sub fill_photos_of_album {
	my %params = @_;
	
	if (defined $photos_of_album{ $params{album_id} }) {
		return 1;
	}
	
	my $response = $ua->post(
        $conf{base_url}.'/ws.php?format=json',
        {
            method => 'pwg.categories.getImages',
            cat_id => $params{album_id},
        }
    );
    
    foreach my $image_href (@{from_json($response->content)->{result}{images}{_content}}) {
    	$photos_of_album{ $params{album_id} }{ $image_href->{file} } = 1;
    }
}

sub photo_exists {
	my %params = @_;

    fill_photos_of_album(album_id => $params{album_id});
    
    if (defined $photos_of_album{ $params{album_id} }{ $params{file} }) {
    	return 1;
    }
    else {
    	return 0;
    }
}

sub add_album {
	my %params = @_;
	
	# print Dumper(\%params);
	
    my $form = {
        method => 'pwg.categories.add',
        name => $params{name},
    };
    
    if (defined $params{parent}) {
    	$form->{parent} = $params{parent};
    }

    my $response = $ua->post(
        $conf{base_url}.'/ws.php?format=json',
        $form
    );

    return from_json($response->content)->{result}{id};
}

sub add_photo {
    my %params = @_;

    my $form = {
        method => 'pwg.images.addSimple',
        image => [$params{path}],
        category => $params{album_id},
    };

    # is there any title defined in a descript.ion file?
    my $property = undef;
    my $desc_filepath = dirname($params{path}).'/descript.ion';
    if (-f $desc_filepath) {
        my $photo_filename = basename($params{path});
        open(IN, '<', $desc_filepath);
        while (my $desc_line = <IN>) {
            if ($desc_line =~ /^$photo_filename/) {
                chomp($desc_line);
                $property = (split /\t/, $desc_line, 2)[1];
            }
        }
        close(IN);
    }

    if (defined $property and $property ne '') {
        $form->{name} = $property;
    }

    my $response = $ua->post(
        $conf{base_url}.'/ws.php?format=json',
        $form,
        'Content_Type' => 'form-data',
    );
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
            if (not defined $piwigo_albums{$up_dir.$dir}) {
                print 'album "'.$up_dir.$dir.'" must be created'."\n";
                my $id = add_album(name => $dir, parent => $parent_id);
                $piwigo_albums{$up_dir.$dir} = $id;
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

        if (photo_exists(album_id => $album_id, file => basename($File::Find::name))) {
            if (not $opt{quiet}) {
                print $File::Find::name.' already exists in Piwigo, skipped'."\n";
            }
            return 1;
        }

        print $File::Find::name.' must be uploaded in "'.$album_key.'" (id='.$album_id.')'."\n";
        add_photo(path => $File::Find::name, album_id => $album_id);
        # print 'dirname = '.dirname($path)."\n\n";
    }
}
