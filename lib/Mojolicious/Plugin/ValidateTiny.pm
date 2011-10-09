package Mojolicious::Plugin::ValidateTiny;
use Mojo::Base 'Mojolicious::Plugin';

use v5.10;
use strict;
use warnings;

use Carp qw/croak/;
 
use Data::Dumper;
use Validate::Tiny;
use Mojo::Util qw/camelize/;
use v5.10;

our $VERSION = '0.04';

# TODO check in after_static_dispatch hook that there are params and should be validated
# in after_dispatch hook check that in action validation was called

sub register {
    my ( $self, $app, $conf ) = @_;
    my $log = $app->log;

    # Processing config
    $conf = {
        strict    => 0,
        autorules => 0,
        exclude   => [],
        %{ $conf || {} } };

    if ( $conf->{autorules} && ref $conf->{autorules} ne 'CODE' ) {
        $conf->{autorules} = 0;

    }

    # Helper do_validation
    $app->helper(
        do_validation => sub {
            my ( $c, $rules, $params ) = @_;
            croak "ValidateTiny: Wrong validatation rules"
                unless ref($rules) ~~ [ 'ARRAY', 'HASH' ];

            # Fo not use strict mode if params were passed explicitly
            local $conf->{strict} = 0 if $params;
            
            if (ref $rules eq 'ARRAY') {
                if ( $conf->{strict} ) {
                    die "ValidateTiny: you should pass 'fields' and 'checks' in strict mode!\n";
                } else {
                    $rules = { checks => $rules };
                }
            }

            # Validate GET+POST parameters by default
            $params ||= $c->req->params->to_hash;
            $rules->{fields} ||= [];
            push @{$rules->{fields}}, keys %$params;
            my %h;
            @{$rules->{fields}} = grep { !$h{$_}++ } @{$rules->{fields}};    

            # Check that there is an individual rule for every field
            if ( $conf->{strict} ) {
                my %h = @{ $rules->{checks} };
                my @fields_wo_rules;

                foreach my $f ( @{ $rules->{fields} } ) {
                    next if $f ~~ $conf->{exclude};
                    push @fields_wo_rules, $f unless exists $h{$f};
                }

                if (@fields_wo_rules) {
                    my $err_msg = 'ValidateTiny: No validation rules for '
                        . join( ', ', map { qq'"$_"' } @fields_wo_rules );
                    die $err_msg . "\n";
                }
            }

            # Do validation
            my $result = Validate::Tiny->new( $params, $rules );
            if ( $result->success ) {
                $log->debug('ValidateTiny: Successful');
                return $result->data;
            } else {
                $log->debug( 'ValidateTiny: Failed: ' . join( ', ', keys %{ $result->error } ) );
                $c->stash( validate_tiny_errors => $result->error );
                return;
            }
        } );

    # Helper validator_has_errors
    $app->helper(
        validator_has_errors => sub {
            my $c      = shift;
            my $errors = $c->stash('validate_tiny_errors');

            return 0 if !$errors || !keys %$errors;
            return 1;
        } );

    # Helper validator_error
    $app->helper(
        validator_error => sub {
            my ( $c, $name ) = @_;
            my $errors = $c->stash('validate_tiny_errors');

            return $errors unless defined $name;

            if ( $errors && defined $errors->{$name} ) {
                return $errors->{$name};
            }
        } );

    # Helper validator_one_error
    $app->helper(
        validator_any_error => sub {
            my ( $c ) = @_;
            my $errors = $c->stash('validate_tiny_errors');
            
            if ( $errors ) {
                return ( ( values %$errors )[0] );
            }
            
            return;
        } );

    # Enabling automatic validation
    if ( my $code = $conf->{autorules} ) {
        $app->hook(
            after_static_dispatch => sub {
                my ($c) = @_;
                my ( $class, $action ) = $self->_get_class_and_action($c);
                return 1 unless $class && $action;
                return 1 unless @{[$c->param]};

                eval {
                    my $rules = $code->( $class, $action );
                    $c->do_validation($rules);
                };

                if ($@) {
                    $log->warn($@);
                
                    $c->rendered(
                        status => 403,
                        text   => "Forbidden!",
                    );

                    return;
                }

                return 1;
            } );
    }
}

sub _get_class_and_action {
    my ( $self, $c ) = @_;
    my $routes = $c->app->routes;

    # Path
    my $req  = $c->req;
    my $path = $c->stash->{path};
    if ( defined $path ) { $path = "/$path" if $path !~ /^\// }
    else                 { $path = $req->url->path->to_abs_string }

    # Match
    my $method    = $req->method;
    my $websocket = $c->tx->is_websocket ? 1 : 0;
    my $m         = Mojolicious::Routes::Match->new( $method => $path, $websocket );
    $m->match($routes);

    # No match
    return unless $m && @{ $m->stack };

    my $field = $m->captures;

    my $action = $field->{action};

    my $class = $self->_generate_class( $field, $c );

    return ( $class, $action );
}

sub _generate_class {
    my ( $self, $field, $c ) = @_;

    # Class
    my $class = $field->{class};
    my $controller = $field->{controller} || '';
    unless ($class) {
        $class = $controller;
        camelize $class;
    }

    # Namespace
    my $namespace = $field->{namespace};
    return unless $class || $namespace;
    $namespace = $c->app->routes->namespace unless defined $namespace;
    $class = length $class ? "${namespace}::$class" : $namespace
        if length $namespace;

    # Invalid
    return unless $class =~ /^[a-zA-Z0-9_:]+$/;

    return $class;
}

1;

=head1 NAME

Mojolicious::Plugin::ValidateTiny - Mojolicious Plugin

=head1 SYNOPSIS

    # Mojolicious
    $self->plugin('ValidateTiny');
    
    # Mojolicious::Lite
    plugin 'ValidateTiny';
    
    sub action {
        my $self = shift;

        # Validate $self->param()    
        my $validate_rules = {};
        if ( my $params =  $self->do_validation($validate_rules) ) {
            # all $params are validated and filters are applyed
            ... do you action ...

            # Validate custom data
            my $rules = {...};
            my $data = {...};
            if ( my $data = $self->do_validation($rules, $data) ) {
                
            } else {
                my $errors_hash = $self->validator_error();
            }            
        } else {
            $self->render(status => '403', text => 'FORBIDDEN');  
        }
        
    }
    
    __DATA__
  
    @@ user.html.ep
    %= if (validator_has_errors) {
        <div class="error">Please, correct the errors below.</div>
    % }
    %= form_for 'user' => begin
        <label for="username">Username</label><br />
        <%= input_tag 'username' %><br />
        <%= validator_error 'username' %><br />
  
        <%= submit_button %>
    % end

  
=head1 DESCRIPTION

L<Mojolicious::Plugin::ValidateTiny> is a L<Validate::Tiny> support in L<Mojolicious>.

=head1 METHODS

L<Mojolicious::Plugin::ValidateTiny> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 C<register>

    $plugin->register;

Register plugin in L<Mojolicious> application.


=head1 HELPERS

=head2 C<validate>

Validates parameters with provided rules and automatically set errors.

$VALIDATE_RULES - Validate::Tiny rules in next form

    {
        checks  => $CHECKS, # Required
        fields  => [],      # Optional (will check all GET+POST parameters)
        filters => [],      # Optional
    }

You can pass only "checks" array to "do_validation". 
In this case validator will take all GET+POST parameters as "fields"

returns false if validation failed
returns true  if validation succeded

    $self->do_validation($VALIDATE_RULES)
    $self->do_validation($CHECKS);

=head2 C<validator_has_errors>

Check if there are any errors.

    %= if (validator_has_errors) {
        <div class="error">Please, correct the errors below.</div>
    % }



=head2 C<validator_error>

Returns the appropriate error.

    my $errors_hash = $self->validator_error();
    my $username_error = $self->validator_error('username');

    <%= validator_error 'username' %>

=head1 SEE ALSO

L<Validate::Tiny>, L<Mojolicious>, L<Mojolicious::Plugin::Validator> 

=cut
