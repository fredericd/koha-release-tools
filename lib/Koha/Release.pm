package Koha::Release;

use Moose;
use Modern::Perl;
use POSIX qw(strftime);
use Template;
use LWP::Simple;
use WWW::Mechanize;
use File::Basename;
use FindBin qw($Bin);
use YAML::Syck qw/ Dump LoadFile /;
use List::MoreUtils qw(uniq);
use Koha::BZ;
use Text::MultiMarkdown;
use HTML::TableExtract;
use Encode qw/encode/;

has version => (
    is => 'rw',
    isa => 'HashRef',
    default => sub {
        my $version;
        eval {
            require 'kohaversion.pl';
            $version = kohaversion();
        };
        say $version;
        my @parts = split /\./, $version;
        die "No usable version" unless @parts == 4;
        if ( $parts[3] =~ /(.*)-(.*)$/ ) {
            push @parts, $2;
            $parts[3] =  $1;
        }
        else {
            push @parts, '';
        }
        $version = {
            major       => $parts[0],
            minor       => $parts[1],
            release     => $parts[2],
            increment   => $parts[3],
            additional  => $parts[4],
            ismajor     => $parts[2] + 0 == 0,
        };
        my $human = "$version->{major}.$version->{minor}.$version->{release}";
        $human =~ s/\.0/\./g;
        $human .= '_' . $version->{additional} if $version->{additional};
        $version->{human} = $human;
        $human =~ s/\./_/g;
        $version->{filesys} = $human;
        return $version;
    },
);

has rootdir => ( is => 'rw', isa => 'Str' );

# Config file: /etc/config.yaml
has c => ( is => 'rw', isa => 'HashRef' );

# The range of commits used to find pacthes included in the release
# For example: v3.22.01..3.22.x
has range => (
    is => 'rw',
    isa => 'Str',
    trigger => sub {
        my ($self, $range) = @_;
        my @commits = qx|git log --pretty='%s' $range 2>/dev/null|;
        if (@commits) {
            say "Range $range: ", scalar(@commits), " commits";
            $self->range_commits(\@commits);
        }
        else {
            say "Invalid range: $range";
            exit 1;
        }
        return $range;
    }
);

has range_commits => ( is => 'rw', isa => 'ArrayRef' );


has bz => (
    is => 'rw',
    isa => 'Koha::BZ',
    lazy => 1,
    builder => '_build_bz'
);


sub trim {
    my ($s) = @_;
    $s =~ s/^\s*(.*?)\s*$/$1/s;
    return $s;
}


sub _build_bz {
    my $c = shift->c->{bz};
    my $login = $ENV{BZ_login} || $c->{login};
    my $password = $ENV{BZ_password} || $c->{password};
    Koha::BZ->new(
        url => $c->{url},
        login => $login,
        password => $password,
    );
}


sub BUILD {
    my $self = shift;

    my $rootdir = dirname(__FILE__) . "/../../";
    $self->rootdir($rootdir);
    my $file = "$rootdir/etc/config.yaml";
    unless ( -e $file ) {
        say "$file doesn't exist";
        exit;
    }
    $self->c(LoadFile($file));
}


sub download_pootle {
    my $self = shift;

    chdir 'misc/translator/po';
    my $version = $self->version->{minor} + 0;
    $version = ".$version" if $version > 18;
    $version = $self->version->{major} . $version . '/';

    # Login to Pootle
    my $c = $self->c->{pootle};
    my $login = $ENV{POOTLE_login} || $c->{login};
    my $password = $ENV{POOTLE_password} || $c->{password};
    my $url = $c->{url} . '/accounts/login/';
    my $mech = WWW::Mechanize->new( autocheck => 0 );
    $mech->get($url);
    $mech->submit_form(
        form_name => 'loginform',
        fields => {
            username => $login,
            password => $password,
        }
    );
    if ( $mech->base() =~ /login\/$/ ) {
        say "Invalid login/password to Pootle";
        exit;
    }

    $mech->get($c->{url} . "/projects/$version");
    my $page = $mech->content;
    my @trans;
    while ($page =~ m#<td class="stats-name">\W*<a href="(.*)">\W*<span>(\w*)</span>\W*</a>\W*</td>\W*<td class="stats-graph">\W*<div class="sortkey">([0-9]*)</div>#g) {
        push @trans, $1;
    }
    for my $url (@trans) {
        say $url;
        $url = $c->{url} . $url . "export/zip";
        $mech->get($url);
        unless ($mech->success()) {
            say "Error getting this ZIP";
            next;
        }
        open my $fh, '>', 'toto.zip';
        print $fh $mech->content;
        close $fh;
        qx|unzip -o toto.zip; rm toto.zip|;
    }
    chdir '../../..';
}

# Get all info about translations from Koha Pootle web site
sub translations {
    my $self = shift;

    # FIXME: before 3.20, naming convention on Pootle was different
    # When 3.18 is not maintained anymore, this could be removed
    my $version = $self->version->{minor} + 0;
    my $sep = '';
    $sep = "."
        if ($self->{version}->{major} == 3 && $version > 18) ||
           not $self->{version}->{major} == 3;
    $version = $self->version->{major} . $sep . $self->version->{minor} . '/';

    my $url = $self->c->{pootle}->{url} . "/projects/$version";
    my $page = get($url);
    unless ($page) {
        say "Unable to get translation at this url: $url";
        return;
    }
    my $translations = [ {language => 'English (USA)'} ];

    my $translations_parser = HTML::TableExtract->new(
        headers => [ "Name", "Progress", "Total", "Need Translation", "Last Activity" ]
    );
    $translations_parser->parse(encode('UTF-8', $page));

    foreach my $language ($translations_parser->rows) {
        next if !defined $language;
        my $name = trim( @$language[0] );
        my $progress = trim( @$language[1] );
        push @$translations, { language => $name, pcent => $progress } if ($progress > 50);
    }

    return $translations;
}


# Return bugs list
sub bugs {
    my ($self, $vars) = @_;

    my $range = $self->range;

    # Just keep the bug number when available in commit message
    my @bugs = @{$self->range_commits};
    @bugs = sort { $a <=> $b } uniq grep { $_ } map {
        m/([B|b]ug|BZ)?\s?(?<![a-z]|\.)(\d{3,5})[\s|:|,]/g ? $2 : 0;
    } @bugs;

    return unless @bugs;

    say "Found bugs: ", (@bugs+0);
    my $response = $self->bz->get('bug?id=' . join(',', @bugs));
    my ($bugs, $bugscount);
    for (@{$response->{bugs}}) {
        my $severity = $_->{severity};
        my $category =
            $severity =~ /blocker|critical|major/ ? 'high'   :
            $severity =~ /normal|minor|trivial/   ? 'normal' :
            $severity =~ /enhancement/            ? 'enh'    : 'feature';
        my $bug = { id => $_->{id}, desc => $_->{summary} };
        $bug->{notes} = $_->{cf_release_notes} if $_->{cf_release_notes};
        push @{$bugs->{$category}->{$_->{component}}}, $bug;
        $category = 'normal' if $category eq 'high';
        $bugscount->{$category}++;
    }
    $vars->{bugs} = $bugs;
    $vars->{bugscount} = $bugscount;
}


# Returns a list of added sysprefs. Find syspref in sysprefs.sql not in
# templates
sub sysprefs {
    my ($self, $vars) = @_;

    my $range = $self->range;
    my ($from, $to) =
        $range =~ /(.*)\.\.(.*)/ ? ($1, $2) : ($range, 'HEAD');

    my %syspref = map {
        my ($where, $pos) = @$_;
        my %all =
            map { $_ => 1 }
            map { /\(\s*'([^']+)'/; $1 }
            grep { /\(\s*'/ }
            qx|git show $pos:installer/data/mysql/sysprefs.sql|;
        $where => \%all
    } ( ['prev', $from], ['curr', $to]);

    my @sysprefs;
    foreach my $pref (sort keys %{$syspref{curr}} ) {
        push @sysprefs, { name => $pref }
            unless $syspref{prev}->{$pref};
    }
    $vars->{sysprefs} = \@sysprefs if @sysprefs;
}


sub info {
    my $self = shift;

    unless ( -e 'kohaversion.pl' ) {
        say "You must run this script being is Koha home directory";
        exit;
    }

    my $version = $self->version;
    my $range = $self->range;

    my $vars = { version => $version };

    $vars->{translations} = $self->translations();

    $vars->{branch} = `git branch | grep '*' | sed -e 's/^* //' -e 's#/#-#'`;
    chomp $vars->{branch};

    my $lastrelease = `grep -E 'Koha [0-9.]* released' docs/history.txt | tail -1`;
    $lastrelease =~ m/^([a-zA-Z]* [0-9]*) ([0-9]*)(  +|\t)Koha ([0-9.]*) released/;
    $vars->{lastrelease}->{date} = "$1, $2";
    $vars->{lastrelease}->{version} = $4;
    $vars->{downloadlink} = "http://download.koha-community.org/koha-" .
        "$version->{major}.$version->{minor}.$version->{release}.tar.gz";

    $self->bugs($vars);
    $self->sysprefs($vars);

    # Now we'll alphabetize the contributors based on surname (or at least the
    # last word on their line)
    $vars->{contributors} = [ map {
        /\s*(\d*)\s*(.*)\s*$/;
        { name => $2, commits => $1 }
    } qx(git log --pretty=short $range | git shortlog -s | sort -k3 -) ];

    $vars->{signers} = [ map {
        /\s*(\d*)\s*(.*)\s*$/;
        { name => $2, signoffs => $1 }
    } qx(git log $range | grep 'Signed-off-by' |
         sed -e 's/^.*Signed-off-by: //' |
         sed -e 's/ <.*\$//' | sort -k3 - | uniq -c) ];

    $vars->{sponsors} = [ map { chop; $_; }
        qx(git log $range | grep 'Sponsored-by' |
           sed -e 's/^.*Sponsored-by: //' | sort | uniq) ];

    # contributing companies, with their number of commits, by alphabetical
    # order companies are retrieved from the email address. generic emails
    # like hotmail.com, gmail.com are cumulated in a "undentified"
    # contributor
    my $map = $self->c->{domainmap};
    my $companies;
    foreach (
        qx(git log --pretty=short $range | git shortlog -s -e | sort -k3 -) )
    {
        chop;
        /(\d+).*@(.*)>/;
        my ($nbpatch, $company) = ($1,$2);
        $company = 'unidentified'
            if $company =~ /o2\.pl|gmail\.com|hotmail\.com|\(none\)|yahoo/;
        $company = $map->{$company} if $map->{$company};
        $companies->{$company} += $nbpatch;
    }
    $vars->{companies} = [
        map { { name => $_, commits => $companies->{$_} } }
        sort { lc $a cmp lc $b } keys %$companies
    ];

    $vars->{date} = strftime "%d %b %Y", gmtime;
    $vars->{timestamp} = strftime("%d %b %Y %T", gmtime);

    # Team retrieved from config.yaml
    my $team = $self->c->{team}->{$self->c->{master}};
    $team->{manager} = $self->{c}->{team}->{"$version->{major}.$version->{minor}"}->{manager},
    $vars->{team} = $team;

    return $vars;
}


sub _md_file {
    my $self = shift;
    my $version = $self->version;
    return "misc/release_notes/release_notes_$version->{filesys}.md";
}


sub build_notes {
    my ($self, $html) = @_;

    my $file = $self->_md_file();
    say "Generate Markdown release notes file: $file";

    my $tt;
    $tt = Template->new({
        INCLUDE_PATH => $self->rootdir . '/etc',
        ENCODING => 'utf8',
    }) || die $tt->error(), "\n";    
    my $vars = $self->info();
    $tt->process("notes.tt", $vars, $file) || die $tt->error(), "\n";

}


sub build_html {
    my ($self, $html) = @_;

    my $file = $self->_md_file();
    say "Generate HTML release notes file '$html' from '$file'";
    unless (-e $file) {
        say "$file doesn't exist. You have to run 'koha-release range notes' first.";
        exit;
    }
    open(my $fh, '>', $html) or die "Unable to create $file: $!";
    my $m = Text::MultiMarkdown->new();
    my $text = qx|cat $file|;
    #utf8::encode($text);
    print $fh $m->markdown($text);
}


1;
