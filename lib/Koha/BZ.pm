package Koha::BZ;

use Moose;
use Modern::Perl;
use JSON;
use REST::Client;


has client => (is => 'rw', isa => 'REST::Client');
has url => (is => 'rw', isa => 'Str');
has login => (is => 'rw', isa => 'Str');
has password => (is => 'rw', isa => 'Str');
has token => (is => 'rw', isa => 'Str');



sub get {
    my ($self, $cmd, $args) = @_;
    my $url = $self->url . "/rest/$cmd?" .
              join('&', map { "$_=" . $args->{$_} } keys %$args);
    $url .= '&token=' . $self->token if $self->token;
    $self->client->GET($url);
    decode_json($self->client->responseContent());
}


sub BUILD {
    my $self = shift;

    $self->client( REST::Client->new() );

    if ( $self->login ) {
        my $response = $self->get('login', {
            login => $self->login,
            password => $self->password,
        });
        if ( $response->{error} ) {
            say "Wrong login/password to BZ";
            exit 1;
        }
        $self->token($response->{token});
    }
}

1;