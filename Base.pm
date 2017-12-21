package Koha::Illbackends::Koha::Base;

# Copyright PTFS Europe 2014
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;
use DateTime;
use Koha::Illrequestattribute;
use Koha::Patrons;
use LWP::UserAgent;
use URI;
use URI::Escape;
use XML::LibXML;
use MARC::Record;
use MARC::File::XML;

=head1 NAME

Koha::Illrequest::Backend::Dummy - Koha ILL Backend: Dummy

=head1 SYNOPSIS

Koha ILL implementation for the "Dummy" backend.

=head1 DESCRIPTION

=head2 Overview

We will be providing the Abstract interface which requires we implement the
following methods:
- create        -> initial placement of the request for an ILL order
- confirm       -> confirm placement of the ILL order
- renew         -> request a currently borrowed ILL be renewed in the backend
- cancel        -> request an already 'confirm'ed ILL order be cancelled
- status        -> request the current status of a confirmed ILL order
- status_graph  -> return a hashref of additional statuses

Each of the above methods will receive the following parameter from
Illrequest.pm:

  {
      request    => $request,
      other      => $other,
  }

where:

- $REQUEST is the Illrequest object in Koha.  It's associated
  Illrequestattributes can be accessed through the `illrequestattributes`
  method.
- $OTHER is any further data, generally provided through templates .INCs

Each of the above methods should return a hashref of the following format:

    return {
        error   => 0,
        # ^------- 0|1 to indicate an error
        status  => 'result_code',
        # ^------- Summary of the result of the operation
        message => 'Human readable message.',
        # ^------- Message, possibly to be displayed
        #          Normally messages are derived from status in INCLUDE.
        #          But can be used to pass API messages to the INCLUDE.
        method  => 'status',
        # ^------- Name of the current method invoked.
        #          Used to load the appropriate INCLUDE.
        stage   => 'commit',
        # ^------- The current stage of this method
        #          Used by INCLUDE to determine HTML to generate.
        #          'commit' will result in final processing by Illrequest.pm.
        next    => 'illview'|'illlist',
        # ^------- When stage is 'commit', should we move on to ILLVIEW the
        #          current request or ILLLIST all requests.
        value   => {},
        # ^------- A hashref containing an arbitrary return value that this
        #          backend wants to supply to its INCLUDE.
    };

=head2 On the Dummy backend

The Dummy backend is rather simple, but provides correctly formatted response
values, that other backends can model themselves after.

The code is not DRY -- primarily so that each method can be looked at in
isolation rather than having to familiarise oneself with helper procedures.

=head1 API

=head2 Class Methods

=cut

=head3 new

  my $backend = Koha::Illrequest::Backend::Dummy->new;

=cut

sub new {
    # -> instantiate the backend
    my ( $class ) = @_;
    my $self = {
        ua      => LWP::UserAgent->new,
        targets => {
            'Demo Koha Instance' => {
                SRU => 'http://demo.koha-ptfs.eu:9998/biblios',
                ILSDI => 'https://demo.koha-ptfs.eu/cgi-bin/koha/ilsdi.pl',
            },
        },
    };
    bless( $self, $class );
    return $self;
}

sub name {
    return "Koha";
}

=head3 metadata

Return a hashref containing canonical values from the key/value
illrequestattributes store.

=cut

sub metadata {
    my ( $self, $request ) = @_;
    my $attrs = $request->illrequestattributes;
    return {
        ID     => $attrs->find({ type => 'id' })->value,
        Title  => $attrs->find({ type => 'title' })->value,
        Author => $attrs->find({ type => 'author' })->value,
        Status => $attrs->find({ type => 'status' })->value,
    }
}

=head3 capabilities

    $capability = $backend->capabilities($name);

Return the sub implementing a capability selected by NAME, or 0 if that
capability is not implemented.

=cut

sub capabilities {
    my ( $self, $name ) = @_;
    my $capabilities = {
        # We don't implement unmediated for now
        # unmediated_ill => sub { $self->confirm(@_); }
    };
    return $capabilities->{$name};
}

=head3 _data_store

  my $request = $self->_data_store($id);
  my $requests = $self->_data_store;

A mock of a data store.  When passed no parameters it returns all entries.
When passed one it will return the entry matched by its id.

=cut

sub _data_store {
    my $data = {
        1234 => {
            id     => 1234,
            title  => "Ordering ILLs using Koha",
            author => "A.N. Other",
            status => "New",
        },
        5678 => {
            id     => 5678,
            title  => "Interlibrary loans in Koha",
            author => "A.N. Other",
            status => "New",
        },
    };
    # ID search
    my ( $self, $id ) = @_;
    return $data->{$id} if $id;

    # Full search
    my @entries;
    while ( my ( $k, $v ) = each %{$data} ) {
        push @entries, $v;
    }
    return \@entries;
}

=head3 status_graph

=cut

sub status_graph {
    return {};
}

=head3 create

  my $response = $backend->create({
      request    => $requestdetails,
      other      => $other,
  });

This is the initial creation of the request.  Generally this stage will be
some form of search with the backend.

By and large we will not have useful $requestdetails (borrowernumber,
branchcode, status, etc.).

$params is simply an additional slot for any further arbitrary values to pass
to the backend.

This is an example of a multi-stage method.

=cut

sub create {
    # -> initial placement of the request for an ILL order
    my ( $self, $params ) = @_;
    my $other = $params->{other};
    my $stage = $other->{stage};
    if ( !$stage || $stage eq 'init' ) {
        # We simply need our template .INC to produce a search form.
        return {
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'search_form',
            value   => $params,
        };
    } elsif ( $stage eq 'search_form' ) {
	# Received search query in 'other'; perform search...
        my ( $brw_count, $brw )
            = _validate_borrower($other->{'cardnumber'}, $stage);
        my $result = {
            status  => "",
            message => "",
            error   => 1,
            value   => {},
            method  => "create",
            stage   => "init",
        };
        if ( _fail($other->{'branchcode'}) ) {
            $result->{status} = "missing_branch";
            $result->{value} = $params;
            return $result;
        } elsif ( !Koha::Libraries->find($other->{'branchcode'}) ) {
            $result->{status} = "invalid_branch";
            $result->{value} = $params;
            return $result;
        } elsif ( $brw_count == 0 ) {
            $result->{status} = "invalid_borrower";
            $result->{value} = $params;
            return $result;
        } elsif ( $brw_count > 1 ) {
            # We must select a specific borrower out of our options.
            $params->{brw} = $brw;
            $result->{value} = $params;
            $result->{stage} = "borrowers";
            $result->{error} = 0;
            return $result;
        } else {
            # We perform the search!
            $other->{borrowernumber} = $brw->borrowernumber;
            return $self->_search($params);
        }

    } elsif ( $stage eq 'search_results' ) {
        # We have a selection
        my $id = $params->{other}->{id};

        # -> select from backend...
        my $request_details = $self->_data_store($id);

        # Establish borrower
        my $brwnum;
        if ( $params->{other}->{cardnumber} ) {
            # OPAC request
            my $brw = Koha::Patrons->find({
                cardnumber => $params->{other}->{cardnumber}
            });
            $brwnum = $brw->borrowernumber;
        } else {
            $brwnum = $params->{other}->{borrowernumber};
        }
        # ...Populate Illrequest
        my $request = $params->{request};
        $request->borrowernumber($brwnum);
        $request->branchcode($params->{other}->{branchcode});
        $request->medium($params->{other}->{medium});
        $request->status('NEW');
	$request->backend($params->{other}->{backend});
        $request->placed(DateTime->now);
        $request->updated(DateTime->now);
        $request->store;
        # ...Populate Illrequestattributes
        while ( my ( $type, $value ) = each %{$request_details} ) {
            Koha::Illrequestattribute->new({
                illrequest_id => $request->illrequest_id,
                type          => $type,
                value         => $value,
            })->store;
        }

        # -> create response.
        return {
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'commit',
            next    => 'illview',
            value   => $request_details,
        };
    } else {
	# Invalid stage, return error.
        return {
            error   => 1,
            status  => 'unknown_stage',
            message => '',
            method  => 'create',
            stage   => $params->{stage},
            value   => {},
        };
    }
}

=head3 confirm

  my $response = $backend->confirm({
      request    => $requestdetails,
      other      => $other,
  });

Confirm the placement of the previously "selected" request (by using the
'create' method).

In this case we will generally use $request.
This will be supplied at all times through Illrequest.  $other may be supplied
using templates.

=cut

sub confirm {
    # -> confirm placement of the ILL order
    my ( $self, $params ) = @_;
    # Turn Illrequestattributes into a plain hashref
    my $value = {};
    my $attributes = $params->{request}->illrequestattributes;
    foreach my $attr (@{$attributes->as_list}) {
        $value->{$attr->type} = $attr->value;
    };
    # Submit request to backend...

    # No-op for Dummy

    # ...parse response...
    $attributes->find({ type => "status" })->value('On order')->store;
    my $request = $params->{request};
    $request->cost("30 GBP");
    $request->orderid($value->{id});
    $request->status("REQ");
    $request->accessurl("URL") if $value->{url};
    $request->store;
    $value->{status} = "On order";
    $value->{cost} = "30 GBP";
    # ...then return our result:
    return {
        error    => 0,
        status   => '',
        message  => '',
        method   => 'confirm',
        stage    => 'commit',
        next     => 'illview',
        value    => $value,
    };
}

=head3 renew

  my $response = $backend->renew({
      request    => $requestdetails,
      other      => $other,
  });

Attempt to renew a request that was supplied through backend and is currently
in use by us.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub renew {
    # -> request a currently borrowed ILL be renewed in the backend
    my ( $self, $params ) = @_;
    # Turn Illrequestattributes into a plain hashref
    my $value = {};
    my $attributes = $params->{request}->illrequestattributes;
    foreach my $attr (@{$attributes->as_list}) {
        $value->{$attr->type} = $attr->value;
    };
    # Submit request to backend, parse response...
    my ( $error, $status, $message ) = ( 0, '', '' );
    if ( !$value->{status} || $value->{status} eq 'On order' ) {
        $error = 1;
        $status = 'not_renewed';
        $message = 'Order not yet delivered.';
    } else {
        $value->{status} = "Renewed";
    }
    # ...then return our result:
    return {
        error   => $error,
        status  => $status,
        message => $message,
        method  => 'renew',
        stage   => 'commit',
        value   => $value,
        next    => 'illview',
    };
}

=head3 cancel

  my $response = $backend->cancel({
      request    => $requestdetails,
      other      => $other,
  });

We will attempt to cancel a request that was confirmed.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub cancel {
    # -> request an already 'confirm'ed ILL order be cancelled
    my ( $self, $params ) = @_;
    # Turn Illrequestattributes into a plain hashref
    my $value = {};
    my $attributes = $params->{request}->illrequestattributes;
    foreach my $attr (@{$attributes->as_list}) {
        $value->{$attr->type} = $attr->value;
    };
    # Submit request to backend, parse response...
    my ( $error, $status, $message ) = (0, '', '');
    if ( !$value->{status} ) {
        ( $error, $status, $message ) = (
            1, 'unknown_request', 'Cannot cancel an unknown request.'
        );
    } else {
        $attributes->find({ type => "status" })->value('Reverted')->store;
        $params->{request}->status("REQREV");
        $params->{request}->cost(undef);
        $params->{request}->orderid(undef);
        $params->{request}->store;
    }
    return {
        error   => $error,
        status  => $status,
        message => $message,
        method  => 'cancel',
        stage   => 'commit',
        value   => $value,
        next    => 'illview',
    };
}

=head3 status

  my $response = $backend->create({
      request    => $requestdetails,
      other      => $other,
  });

We will try to retrieve the status of a specific request.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub status {
    # -> request the current status of a confirmed ILL order
    my ( $self, $params ) = @_;
    my $value = {};
    my $stage = $params->{other}->{stage};
    my ( $error, $status, $message ) = (0, '', '');
    if ( !$stage || $stage eq 'init' ) {
        # Generate status result
        # Turn Illrequestattributes into a plain hashref
        my $attributes = $params->{request}->illrequestattributes;
        foreach my $attr (@{$attributes->as_list}) {
            $value->{$attr->type} = $attr->value;
        }
        ;
        # Submit request to backend, parse response...
        if ( !$value->{status} ) {
            ( $error, $status, $message ) = (
                1, 'unknown_request', 'Cannot query status of an unknown request.'
            );
        }
        return {
            error   => $error,
            status  => $status,
            message => $message,
            method  => 'status',
            stage   => 'status',
            value   => $value,
        };

    } elsif ( $stage eq 'status') {
        # No more to do for method.  Return to illlist.
        return {
            error   => $error,
            status  => $status,
            message => $message,
            method  => 'status',
            stage   => 'commit',
            next    => 'illlist',
            value   => {},
        };

    } else {
        # Invalid stage, return error.
        return {
            error   => 1,
            status  => 'unknown_stage',
            message => '',
            method  => 'create',
            stage   => $params->{stage},
            value   => {},
        };
    }
}

=head3 search

    my $results = $bldss->search($query, $opts);

Return an array of Record objects.

The optional OPTS parameter specifies additional options to be passed to the
API. For now the options we use in the ILL Module are:
 max_results -> SearchRequest.maxResults,
 start_rec   -> SearchRequest.start,
 isbn        -> SearchRequest.Advanced.isbn
 issn        -> SearchRequest.Advanced.issn
 title       -> SearchRequest.Advanced.title
 author      -> SearchRequest.Advanced.author
 type        -> SearchRequest.Advanced.type
 general     -> SearchRequest.Advanced.general

We simply pass the options hashref straight to the backend.

=cut

sub _search {
    my ( $self, $params ) = @_;
    my $other = $params->{other};
    my $query = $other->{query};
    my $borrowernumber = $other->{borrowernumber};
    my $brw = Koha::Patrons->find($borrowernumber);
    my $branch = $other->{branchcode};
    my $backend = $other->{backend};
    my %opts = map { $_ => $other->{$_} }
        qw/ search max_results start_rec /;
    my $opts = \%opts;

    $opts->{max_results} = 10 unless $opts->{max_results};
    $opts->{start_rec} = 1 unless $opts->{start_rec};

    my $results = [];

    my $args = {
        version => '1.1',
        operation => 'searchRetrieve',
        query => $opts->{search},
        startRecord => $opts->{start_rec},
        maximumRecords => $opts->{max_results},
        recordSchema => 'marcxml',
    };
    my $key_pairs  = [];
    foreach my $k ( keys %{$args} ) {
        push @{$key_pairs}, $k, $args->{$k};
    }

    my $searches = {};
    foreach my $target ( keys %{$self->{targets}} ) {
        my $url = URI->new($self->{targets}->{$target}->{SRU});
        $url->query_form( $key_pairs );
        my $req = HTTP::Request->new( 'GET' => $url );
        $req->header('Content-Type' => 'text/xml');
        my $res = $self->{ua}->request($req);
        if ( $res->is_success ) {
            $searches->{$target} = MARC::Record->new_from_xml( 'XML', $res->content);
        } else {
            die("Error requesting from target", $res->status_line, $res->content);
        }
    }

    use Data::Dump qw/dump/;
    die dump($searches);

    # Perform the search in the API
    my $response = $self->_process($self->_api->search($query, $opts));

    # Augment Response with standard values
    $response->{method} = "create";
    $response->{stage} = "search";
    $response->{borrowernumber} = $borrowernumber;
    $response->{cardnumber} = $brw->cardnumber;
    $response->{branchcode} = $branch;
    $response->{backend} = $backend;
    $response->{query} = $query;
    $response->{params} = $params;

    # Build user search string & paging query string
    my $nav_qry = "?method=create&stage=search_cont&query="
        . uri_escape($query);
    $nav_qry .= "&borrowernumber=" . $borrowernumber;
    $nav_qry .= "&branchcode=" . $branch;
    $nav_qry .= "&backend=" . $backend;
    my $userstring = "[keywords: " . $query . "]";
    while ( my ($type, $value) = each %{$opts} ) {
        $userstring .= "[" . join(": ", $type, $value) . "]";
        $nav_qry .= "&" . join("=", $type, $value)
            unless ( 'start_rec' eq $type );
    }
    $response->{userstring} = $userstring;

    # Handle errors
    if ( $response->{error} && $response->{status} eq 'search_fail' ) {
        # Ignore 'search_fail' result: empty resultset
        $response->{error} = 0
    } elsif ( $response->{error} ) {
        # Return on other error
        return $response;
    }

    # Else populate response values.
    my @return;
    my $spec = $self->getSpec;
    foreach my $datum ( @{$response->{value}->result->records} ) {
	my $record = $self->_parseResponse($datum, $spec, {});
        push (@return, $record);
    }
    $response->{value} = \@return;

    # Finalise paging query string
    my $result_count = @return;
    my $current_pos  = $opts->{start_rec};
    my $next_pos = $current_pos + $result_count;
    my $next = $nav_qry . "&start_rec=" . $next_pos
        if ( $result_count == $opts->{max_results} );
    my $prev_pos = $current_pos - $result_count;
    my $previous = $nav_qry . "&start_rec=" . $prev_pos
        if ( $prev_pos >= 1 );
    $response->{next} = $next;
    $response->{previous} = $previous;

    # Return search results
    return $response;
}

=head3 _fail

=cut

sub _fail {
    my @values = @_;
    foreach my $val ( @values ) {
        return 1 if (!$val or $val eq '');
    }
    return 0;
}

=head3 _validate_borrower

=cut

sub _validate_borrower {
    # Perform cardnumber search.  If no results, perform surname search.
    # Return ( 0, undef ), ( 1, $brw ) or ( n, $brws )
    my ( $input, $action ) = @_;
    my $patrons = Koha::Patrons->new;
    my ( $count, $brw );
    my $query = { cardnumber => $input };
    $query = { borrowernumber => $input } if ( $action eq 'search_cont' );

    my $brws = $patrons->search( $query );
    $count = $brws->count;
    my @criteria = qw/ surname firstname end /;
    while ( $count == 0 ) {
        my $criterium = shift @criteria;
        return ( 0, undef ) if ( "end" eq $criterium );
        $brws = $patrons->search( { $criterium => $input } );
        $count = $brws->count;
    }
    if ( $count == 1 ) {
        $brw = $brws->next;
    } else {
        $brw = $brws;           # found multiple results
    }
    return ( $count, $brw );
}

=head1 AUTHOR

Alex Sassmannshausen <alex.sassmannshausen@ptfs-europe.com>

=cut

1;
