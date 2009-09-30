package Perlanet::Filters;

sub create_filter {
    my $class = shift;
    my $cfg = shift;

    unless ($cfg) {
        return bless {}, Perlanet::Filter::Null;
    }

    # if ARRAY, then chain

    if      ($cfg->{type} eq 'category') {
        return Perlanet::Filter::Category->new($cfg->{category});
    }
    elsif   ($cfg->{type} eq 'vingrad') {
        return bless {}, Perlanet::Filter::Vingrad;
    }

    die "Unknown filter type requested: $cfg->{type}\n";
}

sub filter {
    my $class = shift;
    my $cfg = shift;

    my $filter = $class->create_filter($cfg);

    return $filter->filter(@_);
}

package Perlanet::Filter::Null;

sub filter {
    my $self = shift;
    return @_;
}

package Perlanet::Filter::Category;
use List::Util qw/first/;

sub new {
    my $class = shift;
    my $self = {};
    $self->{category} = shift;

    $self->{category} = [ $self->{category} ] unless ref $self->{category} eq 'ARRAY';

    bless $self, $class;
}

sub filter {
    my $self = shift;
    my @rv;

    ENTRY:
    foreach my $e (@_) {
        foreach my $cat ($e->category) {
            if (first { $cat eq $_ } @{$self->{category}}) {
                push @rv, $e;
                next ENTRY;
            }
        }
    }

    return @rv;
}

package Perlanet::Filter::Vingrad;
use List::Util qw/first/;

sub filter {
    my $self = shift;
    my @rv;

    ENTRY:
    foreach my $e (@_) {
        my $text = $e->content->body;

        $text =~ /<table class='quote'/ and next; # most probably a comment

        $text =~ s/<table>.+<td>.+<td>(.+)<\/td>.+<\/table>/$1/s;

        $e->content($text);

        push @rv, $e;
    }

    return @rv;
}


1;
