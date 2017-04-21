#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper;
use LWP::UserAgent;
use JSON::PP;
use HTML::TreeBuilder 5 -weak;
use HTML::TreeBuilder::XPath;
use IO::Socket::SSL;

binmode(STDOUT,':utf8');

my $agent = 'Mozilla/5.0 (X11; Linux x86_64; rv:52.0) Gecko/20100101 Firefox/52.0';
my $ua = LWP::UserAgent->new(
	agent => $agent,
);
my $ua_ssl_relaxed = LWP::UserAgent->new(
	agent => $agent,
	ssl_opts => {
		verify_hostname => 0,
	},
);
my $json_relaxed = JSON::PP->new->allow_barekey->allow_singlequote->relaxed;
my $json = JSON::PP->new;
my $extend_cur_pattern = qr/
	extend\s*\(\s*
		cur\s*,\s*
		\{
			(
				(?:
					\{(?-1)\}
				|
					[^{}]+
				)*
			)
		\}
   \s*\)
/xs;

my ($scheme, $domain);

sub startsWith {
	my ($str, $prefix) = @_;
	return substr($str, 0, length($prefix)) eq $prefix;
}

sub getContent {
	my ($response) = @_;
	$response->is_success or die $response->status_line;
	$response->content_type eq 'text/html' or die $response->content_type;
	$response->content_charset eq 'WINDOWS-1251' or die $response->content_charset;
	return $response->decoded_content;
}

sub getItemsCount {
	my ($from, $from_name, $count_name, $filter) = @_;
	my $content = getContent($ua->get("$scheme://$domain/$from"));

	my %cur;
	while ($content =~ /$extend_cur_pattern/g) {
		my $jstr = "{$1}";
		defined $filter and $jstr =~ s/$filter//;
		my $jobj = $json_relaxed->decode($jstr);
		my %jobj = %$jobj;
		@cur{ keys %jobj } = values %jobj;
	}
	$cur{$from_name} eq $from or die $cur{$from_name}.' '.$from;
	return $cur{$count_name};
}

sub ajaxRequest {
	my ($from, $query) = @_;
	my $content = getContent($ua->post("$scheme://$domain/$from", $query));
	
	$content =~ s/^<!--//;
	my @answer = split('<!>', $content);
	scalar @answer >= 5 or die;
	my ($navVersion, $newStatic, $langId, $langVer, $code, @rest) = @answer;
	$code == 0 or die $code;
	
	return @rest;
}

sub photosLoad {
	my ($from, $count, $cb) = @_;
	my $offset = 0;
	while ($offset < $count) {
		my @answer = ajaxRequest($from, {
			al => 1,
			offset => $offset,
			part => 1,
		});
		scalar @answer > 1 or die;
		my $off = shift @answer;
		$off =~ s/^<!int>// or die $off;
		$offset = $off;
		
		&$cb(@answer);
	}
}

sub getAlbums {
	my ($albums_id) = @_;

	my $albumCount = getItemsCount(
		$albums_id,
		'moreFromAlbums',
		'albumsCount',
		qr/\s*onPrivacyChanged:\s*photos.privacy\s*,?/
	);
	print "albumCount: $albumCount\n";

	my @albums;
	photosLoad($albums_id, $albumCount, sub {
		scalar @_ == 3 or die;
		my ($rows, $privacy, $album) = @_;
		$privacy =~ s/^<!json>// or die $privacy;
		$album eq 'albums' or die; # TODO: hotfixed, remove?
	
		my $html = HTML::TreeBuilder::XPath->new;
		$html->parse_content($rows);
		my $photo_row_set_xpath = './/div[contains(concat(" ", normalize-space(@class), " "), " photo_row ")]';
		my @photo_rows = $html->findnodes($photo_row_set_xpath);
		scalar @photo_rows > 0 or die;

		for my $photo_row(@photo_rows) {
			my $img_link_set_xpath = './/a[contains(concat(" ", normalize-space(@class), " "), " img_link ")]';
			my $img_link_set = $photo_row->findnodes($img_link_set_xpath);
			$img_link_set->size == 1 or die $img_link_set->size;
			my $img_link = $img_link_set->shift;
			my $album_href = $img_link->attr('href');
			defined $album_href or die;
			$album_href =~ s/^\///;

			my $title_xpath = './/div[contains(concat(" ", normalize-space(@class), " "), " photos_album_title ")]';
			$img_link->exists($title_xpath) or die;
			my $title = $img_link->findvalue($title_xpath);

			push @albums, {href => $album_href, title => $title};
		}

		$html->delete;
	});
	scalar @albums == $albumCount or die;
	return @albums;
}

sub getDecPrintFormat {
	my ($num) = @_;
	my $len;
	if ($num == 0) {
		$len = 1;
	} elsif ($num > 0) {
		$len = 0;
		my $pow = 1;
		while($num >= $pow) {$pow *= 10; $len++}
	} else {
		die;
	}
	return '%0'.$len.'u';
}

sub downloadAlbum {
	my ($album_href, $base_path) = @_;
	
=cuts
	my $photoCount = getItemsCount($album_href, 'moreFrom', 'count');

	my @photos;
	photosLoad($album_href, $photoCount, sub {
		scalar @_ == 1 or die;
		my ($rows) = @_;
	
		my $html = HTML::TreeBuilder->new;
		$html->parse_content($rows);
		my @c = grep {$_->tag eq 'body'} $html->content_list();
		scalar @c == 1 or die;
		my $body = $c[0];
		undef @c;
		$body->tag eq 'body' or die;

		for my $photo_row($body->content_list()) {
			$photo_row->tag eq 'div' or die;
			$photo_row->attr('class') eq 'photo_row' or die;

			my @c = grep {$_->tag eq 'a'} $photo_row->content_list();
			scalar @c == 1 or die;
			my $img_link = $c[0];
			undef @c;
			my $photo_href = $img_link->attr('href');
			defined $photo_href or die;
			$photo_href =~ s/^\///;

			push @photos, $photo_href;
		}

		$html->delete;
	});
=cut
	
	my @pvData;
	my ($off, $cnt) = (0);
	while (1) {
		my @answer = ajaxRequest('al_photos.php', {
			act => 'show',
			al => 1,
			list => $album_href,
			module => 'photos',
			offset => $off,
		});
		scalar @answer == 6 or die;

		my ($listId, $count, $offset, $data, $opts, $candidate) = @answer;
		$count =~ s/^<!int>// or die $count;
		$offset =~ s/^<!int>// or die $offset;
		$data =~ s/^<!json>// or die $data;
		$opts =~ s/^<!json>// or die $opts;
		$candidate eq '<!pageview_candidate>' or die $candidate;
		$offset == $off or die $offset.' '.$off;
		if (defined $cnt) {
			$cnt == $count or die $cnt.' '.$count;
		} else {
			$cnt = $count;
		}
	
		my $jobj = $json->decode($data);
		my @jobj = @$jobj;
		$off = $offset + scalar @jobj;
		if ($off < $cnt) {
			push @pvData, @jobj;
		} else {
			my $size = scalar @jobj - ($off - $cnt);
			push @pvData, @jobj[0..$size-1];
			last;
		}
	}
	defined $cnt && scalar @pvData == $cnt or die;
	print "photoCount: $cnt\n";
	my $photo_number_format = getDecPrintFormat($cnt);
	
	
	my $ph_counter = 1;
	for my $ph(@pvData) {
		my $url;
		{
			my ($d, $s);
			for my $l('w', 'z', 'y', 'x') {
			  if (exists $ph->{$l.'_'})    {$d = $ph->{$l.'_'};    last}
			  if (exists $ph->{$l.'_src'}) {$s = $ph->{$l.'_src'}; last}
			}
			defined $d || defined $s or die;
			my $base = $ph->{base};
			my $add = defined $d ? $d->[0] : $s;
			
			$add !~ /\.[a-z]{3}$/i and $add .= '.jpg';
			if ($add =~ /https?:\/\//i) {
				$url = $add;
			} else {
				if (defined $base) {
					$base =~ s/\/[a-z0-9_:.]*$//i;
				} else {
					$base = '';
				}
				$url = "$base/$add";
			}
		}
		
		my $fname;
		{
			my $number = sprintf $photo_number_format, $ph_counter;
			$ph_counter++;
			my $id = $ph->{id};
			$url =~ /(\.[^.]+)$/ or die;   # get extention (.jpg)
			$fname = "$number photo$id$1";
		}
		
		my $response = $ua_ssl_relaxed->mirror($url, "$base_path/$fname");
		$response->is_success || $response->code == 304 or die $response->status_line;
		startsWith($response->content_type, 'image/') or die $response->content_type;
		print "$fname   $url\n";
	}
}

#=======================

scalar @ARGV == 1 or die;
my $url = $ARGV[0];
$url =~ /^(https?):\/\/([^\/]+)\/(albums-[0-9]+)$/ or die;
my $albums_id;
($scheme, $domain, $albums_id) = ($1, $2, $3);

my $dbase = $albums_id;
-d $dbase or mkdir $dbase or die;

my @albums = getAlbums($albums_id);
my $album_number_format = getDecPrintFormat(scalar @albums);

my $counter = 1;
for (my $i=$#albums; $i>=0; $i--, $counter++) {
	my ($album_href, $dname);
	{
		my $album = $albums[$i];
		$album_href = $album->{href};
		my $title = $album->{title};
		$title =~ s/\//|/g;
		my $number = sprintf $album_number_format, $counter;
		$dname = "$number $album_href $title";

	}
	print "$dname\n";
	-d "$dbase/$dname" or mkdir "$dbase/$dname" or die;
	
	downloadAlbum($album_href, "$dbase/$dname");
}

