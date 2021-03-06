package Perlanet;

use strict;
use warnings;

use Carp;
use Moose;
use Encode;
use List::Util 'min';
use POSIX qw(setlocale LC_ALL);
use URI::Fetch;
use XML::Feed;
use Template;
use DateTime;
use DateTime::Duration;
use YAML 'LoadFile';
use HTML::Tidy;
use HTML::Scrubber;
use POSIX qw//;
use CHI;
use Perlanet::Filters;


use vars qw{$VERSION};

BEGIN {
  $VERSION = '0.36';
}

BEGIN {
    # the semi-official fix for Template Toolkit not to break on UTF-8
    # templates
    use Template::Provider;
    use bytes;
    no warnings 'redefine';
    my $bom = "\x{feff}";
    my $len = length($bom);
    *Template::Provider::_decode_unicode = sub {
        shift;
        my $s = shift;
        # if we have bom, strip it
        $s = substr($s, $len) if substr($s, 0, $len) eq $bom;
        # then decode the string to chars representation
        utf8::decode($s);
        return $s;
    }
}
$XML::Atom::ForceUnicode = 1;

has 'cfg'  => ( is => 'rw', isa => 'HashRef' );
has 'ua'   => ( is => 'rw', isa => 'LWP::UserAgent' );
has 'opml' => ( is => 'rw', isa => 'XML::OPML::SimpleGen');
has 'cache'=> ( is => 'rw' );

=head1 NAME

Perlanet - A program for creating web pages that aggregate web feeds (both
RSS and Atom).

=head1 SYNOPSIS

  my $perlanet = Perlanet->new;
  $perlanet->run;

=head1 DESCRIPTION

Perlanet is a program for creating web pages that aggregate web feeds (both
RSS and Atom). Web pages like this are often called "Planets" after the Python
software which originally popularised them. Perlanet is a planet builder
written in Perl - hence "Perlanet".

The emphasis on Perlanet is firmly on simplicity. It reads web feeds, merges
them and publishes the merged feed as a web page and as a new feed. That's all
it is intended to do. If you want to do more with your feeds (create feeds
from inputs that don't publish feeds, filter or transform them in complex ways
or publish them in interesting ways) then Perlanet isn't the right software
for you. In that case I recommend that you take a look at Plagger - which is
another feed aggregator, but one that is far more complex and, therefore, far
more flexible.

For most uses, you probably don't want to use the Perlanet module. The
L<perlanet> command line program is far more likely to be useful.

=head1 METHODS

=head2 new

The constructor method. One optional argument which is the configuration file.
If not given, this defaults to C<./perlanetrc>.

=cut

sub BUILDARGS {
  my $class = shift;

  @_ or @_ = ('./perlanetrc');

  if ( @_ == 1 && ! ref $_[0] ) {
    open my $cfg_file, '<:utf8', $_[0]
      or croak "Cannot open file $_[0]: $!";
    return { cfg => LoadFile($cfg_file) };
  } else {
    return $class->SUPER::BUILDARGS(@_);
  }
}

sub BUILD {
  my $self = shift;

  $self->ua(LWP::UserAgent->new( agent => $self->cfg->{agent} ||=
                                           "Perlanet/$VERSION" ));
  $self->ua->show_progress(1) if -t STDOUT;

  if ($self->cfg->{cache_dir}) {
    eval { require CHI; };

    if ($@) {
      warn "You need to install CHI to enable caching.\n";
      warn "Caching disabled for this run.\n";
      delete $self->cfg->{cache_dir};
    }
  }

  $self->cfg->{cache_dir}
    and $self->cache(CHI->new(
      driver     => 'File',
      root_dir   => $self->cfg->{cache_dir},
      expires_in => 60 * 60 * 24 * 30,
  ));

  my $opml;
  if ($self->cfg->{opml}) {
    eval { require XML::OPML::SimpleGen; };

    if ($@) {
      warn 'You need to install XML::OPML::SimpleGen to enable OPML ' .
           "Support.\n";
      warn "OPML support disabled for this run.\n";
      delete $self->cfg->{opml};
    } else {
      my $loc = setlocale(LC_ALL, 'C');
      $opml = XML::OPML::SimpleGen->new;
      setlocale(LC_ALL, $loc);
      $opml->head(
        title => $self->cfg->{title},
      );

      $self->opml($opml);
    }
  }
}

=head2 run

The main method which runs the perlanet process.

=cut

sub run {
  my $self = shift;

  my @entries;

  my $day_zero = DateTime->from_epoch(epoch=>0);

  foreach my $f (@{$self->cfg->{feeds}}) {
    my $response = URI::Fetch->fetch($f->{url},
      UserAgent     => $self->ua,
      Cache         => $self->cache || undef,
      ForceResponse => 1,
    );

    if ($response->is_error) {
      warn "$f->{url}:\n" . $response->http_response->status_line . "\n";
      next;
    }

    my $data = $response->content;

    my $feed = eval { XML::Feed->parse(\$data) };

    if ($@) {
      warn "$f->{url}\n$@\n";
      next;
    }

    unless ($feed) {
      warn "$f->{url}\nNo feed\n";
      next;
    }

    if ($feed->format ne $self->cfg->{feed}{format}) {
      $feed = $feed->convert($self->cfg->{feed}{format});
    }

    unless (defined $f->{title}) {
      $f->{title} = $feed->title;
    } 

    my @feed_entries = sort {
      ($b->issued || $day_zero)
        <=>
      ($a->issued || $day_zero)
    } $feed->entries;

    if ($self->cfg->{entries_per_feed} and
      @feed_entries > $self->cfg->{entries_per_feed}) {
      $#feed_entries = $self->cfg->{entries_per_feed} - 1;
    }

    push @entries, Perlanet::Filters->filter($f->{filter},
        map {
            $_->title("$f->{title}: " . ($_->title || '(без заголовка)'));
            $_ } @feed_entries);

    if ($self->opml) {
      $self->opml->insert_outline(
        title   => $f->{title},
        text    => $f->{title},
        xmlUrl  => $f->{url},
        htmlUrl => $f->{web},
      );
    }
  }

  if ($self->opml) {
    $self->opml->save($self->cfg->{opml});
  }

  if ($self->{cfg}{cse_links}) {
    open my $cse_html, '>', $self->{cfg}{cse_links}
        or die "Cannot write CSE links: $!\n";
    foreach my $feed (@{$self->{cfg}{feeds}}) {
        print $cse_html qq{<a href="$feed->{web}">$feed->{web}</a>\n};
    }
  }

  @entries = sort {
                    ($b->issued || $day_zero)
                     <=>
                    ($a->issued || $day_zero)
                  } @entries;

  my $week_in_future = DateTime->now + DateTime::Duration->new(weeks => 1);
  @entries =
    grep { ($_->issued || $_->modified || $day_zero) < $week_in_future }
    @entries;

  # Only need so many entries
  if (@entries > $self->cfg->{entries}) {
    $#entries = $self->cfg->{entries} - 1;
  }

  # Preferences for HTML::Tidy
  my %tidy = (
    doctype      => 'omit',
    output_xhtml => 1,
    wrap         => 0,
    alt_text     => '',
    break_before_br => 0,
    char_encoding => 'raw',
    tidy_mark => 0,
    show_body_only => 1,
    preserve_entities => 1,
    show_warnings => 0,
  );

  # Rules for HTML::Scrub
  my %scrub_rules = (
    img    => {
      src   => qr{^http://},    # only URL with http://
      alt   => 1,               # alt attributes allowed
      align => 1,               # allow align on images
      style => 1,
      '*'   => 0,               # deny all others
    },
    style  => 0,
    script => 0,
    span   => {
      id    => 0,               # blogger(?) includes spans with id attribute
    },
    a      => {
      href  => 1,
      '*'   => 0,
    },
  );

  # Definitions for HTML::Scrub
  my %scrub_def = (
    '*'           => 1,
    'href'        => qr{^(?!(?:java)?script)}i,
    'src'         => qr{^(?!(?:java)?script)}i,
    'cite'        => '(?i-xsm:^(?!(?:java)?script))',
    'language'    => 0,
    'name'        => 1,
    'value'       => 1,
    'onblur'      => 0,
    'onchange'    => 0,
    'onclick'     => 0,
    'ondblclick'  => 0,
    'onerror'     => 0,
    'onfocus'     => 0,
    'onkeydown'   => 0,
    'onkeypress'  => 0,
    'onkeyup'     => 0,
    'onload'      => 0,
    'onmousedown' => 0,
    'onmousemove' => 0,
    'onmouseout'  => 0,
    'onmouseover' => 0,
    'onmouseup'   => 0,
    'onreset'     => 0,
    'onselect'    => 0,
    'onsubmit'    => 0,
    'onunload'    => 0,
    'src'         => 1,
    'type'        => 1,
    'style'       => 1,
    'class'       => 0,
    'id'          => 0,
  );

  my $tidy = HTML::Tidy->new(\%tidy);
  $tidy->ignore( type => TIDY_WARNING );

  my $scrub = HTML::Scrubber->new;
  $scrub->rules(%scrub_rules);
  $scrub->default(1, \%scrub_def);

  my $f = XML::Feed->new($self->cfg->{feed}{format});
  $f->title($self->cfg->{title});
  $f->link($self->cfg->{url});
  $f->description($self->cfg->{description});
  $f->author($self->cfg->{author}{name});
  if ($self->cfg->{feed}{format} eq 'Atom') {
    my $p = $f->{atom}->author;
    $p->email($self->cfg->{author}{email});
  }
  $f->modified(DateTime->now);
  my $self_url = $self->cfg->{self_link} || $self->cfg->{feed}{url} ||
                $self->cfg->{url} . $self->cfg->{feed}{file};
  $f->self_link($self_url);
  $f->id($self_url);

  foreach my $entry (@entries) {
    if ($entry->content->type && $entry->content->type eq 'text/html') {
      my $scrubbed = $scrub->scrub($entry->content->body);
      my $clean = $tidy->clean(utf8::is_utf8($scrubbed) ?
                                 $scrubbed :
                                 decode('utf8', $scrubbed));

      $entry->content($clean);
    }

    $f->add_entry($entry);
  }

  open my $feedfile, '>', $self->cfg->{feed}{file}
    or croak 'Cannot open ' . $self->cfg->{feed}{file} . " for writing: $!";
  print $feedfile $f->as_xml;
  close $feedfile;

  my $tt = Template->new;

  $tt->process($self->cfg->{page}{template},
               { feed => $f, cfg => $self->cfg },
               $self->cfg->{page}{file},
               { binmode => ':utf8'})
    or croak $tt->error;

  if ($self->cfg->{ping}) {
      $self->ua->get($self->cfg->{ping});
  }
}

=head1 TO DO

See http://wiki.github.com/davorg/perlanet

=head1 SUPPORT

There is a mailing list which acts as both a place for developers to talk
about maintaining and improving Perlanet and also for users to get support.
You can sign up to this list at
L<http://lists.mag-sol.com/mailman/listinfo/perlanet>

To report bugs in Perlanet, please use the CPAN request tracker. You can
either use the web page at
L<http://rt.cpan.org/Public/Bug/Report.html?Queue=Perlanet> or send an email
to bug-Perlanet@rt.cpan.org.

=head1 SEE ALSO

=over 4

=item *

L<perlanet>

=item *

L<Plagger>

=back

=head1 AUTHOR

Dave Cross, <dave@mag-sol.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Magnum Solutions Ltd.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=cut

1;
