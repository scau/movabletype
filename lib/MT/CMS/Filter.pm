# Movable Type (r) Open Source (C) 2001-2010 Six Apart, Ltd.
# This program is distributed under the terms of the
# GNU General Public License, version 2.
#
# $Id$

package MT::CMS::Filter;
use strict;
use warnings;

sub save {
    my $app       = shift;
    my $q         = $app->param;
    my $id        = $q->param('id');
    my $author_id = $q->param('author_id') || $app->user->id;
    my $blog_id   = $q->param('blog_id') || 0;
    my $label     = $q->param('label');
    my $ds        = $q->param('datasource');

    if ( !$label ) {
        return $app->json_error(
            $app->translate('Failed to save filter: label is required.') );
    }
    my $items;
    if ( my $items_json = $q->param('items') ) {
        if ( $items_json =~ /^".*"$/ ) {
            $items_json =~ s/^"//;
            $items_json =~ s/"$//;
            $items_json =~ s/\\"/"/g;
        }
        require JSON;
        my $json = JSON->new->utf8(0);
        $items = $json->decode($items_json);
    }
    else {
        $items = [];
    }
    my $filter;
    my $filter_class = MT->model('filter');

    # Search duplicate.
    if (my $dupe = $filter_class->load(
            {   label     => $label,
                object_ds => $ds,
                ( $id ? ( id => { not => $id } ) : () ),
            },
            {   limit      => 1,
                fetch_only => { id => 1 },
            }
        )
        )
    {
        return $app->json_error(
            $app->translate(
                'Failed to save filter: label "[_1]" is duplicated.', $label
            )
        );
    }
    if ($id) {
        $filter = $filter_class->load($id)
            or return $app->json_error( $app->translate('No such filter') );
    }
    else {
        $filter = $filter_class->new;
    }

    $filter->set_values(
        {   author_id => $author_id,
            blog_id   => $blog_id,
            label     => $label,
            object_ds => $ds,
            items     => $items,
        }
    );
    $filter->save
        or return $app->json_error(
        $app->translate( 'Failed to save filter: [_1]', $filter->errstr ) );

    my $list = $q->param('list');
    if ( defined $list && !$list ) {
        my %res;
        my @filters = filters( $app, $ds );
        my $allpass_filter = {
            label => MT->translate('(none)'),
            items => [],
        };
        unshift @filters, $allpass_filter;
        $res{id} = $filter->id;
        $res{filters} = \@filters;
        $res{editable_filter_count} = scalar grep { $_->{can_edit} } @filters;
        return $app->json_result( \%res );
    }
    else {

        # Forward to MT::Common::filterd_list
        $app->forward(
            'filtered_list',
            saved       => 1,
            saved_id    => $filter->id,
            saved_label => $filter->label,
        );
    }
}

sub delete {
    my $app          = shift;
    my $q            = $app->param;
    my $id           = $q->param('id');
    my $filter_class = MT->model('filter');
    my $filter       = $filter_class->load($id)
        or return $app->json_error( $app->translate('No such filter') );
    my $blog_id   = $q->param('blog_id') || 0;
    my $ds        = $q->param('datasource');
    my $user = $app->user;
    if ( $filter->author_id != $user->id && !$user->is_superuser ) {
        return $app->json_error( $app->translate('Permission denied') );
    }
    $filter->remove
        or return $app->json_error(
    $app->translate( 'Failed to delete filter: [_1]', $filter->errstr ) );
    my %res;
    my @filters = filters( $app, $ds );
    my $allpass_filter = {
        label => MT->translate('(none)'),
        items => [],
    };
    unshift @filters, $allpass_filter;
    $res{id} = $filter->id;
    $res{filters} = \@filters;
    $res{editable_filter_count} = scalar grep { $_->{can_edit} } @filters;
    return $app->json_result( \%res );
}

## Note that these filter loading methods below NOT return instances of MT::Filter class.
## they returns a simple hash structure good to encode to JSON.

sub filter {
    my ( $app, $type, $id ) = @_;
    if ( $id && $id !~ /\D/ ) {
        my $filter = MT->model('filter')->load($id) or return;
        return $filter->to_hash;
    }
    return system_filter( $app, $type, $id )
        || legacy_filter( $app, $type, $id );
}

sub system_filter {
    my ( $app, $type, $sys_id ) = @_;
    my $sys_filter = MT->registry( system_filters => $type => $sys_id )
        or return;

    if ( my $cond = $sys_filter->{condition} ) {
        $cond = MT->handler_to_coderef($cond);
        return unless $cond->();
    }

    my $hash = {
        id         => $sys_id,
        label      => $sys_filter->{label},
        items      => $sys_filter->{items},
        can_edit   => 0,
        can_save   => 0,
        can_delete => 0,
    };
    for my $val ( values %$hash ) {
        $val = $val->() if 'CODE' eq ref $val;
    }
    $hash;
}

sub legacy_filter {
    my ( $app, $type, $legacy_id ) = @_;
    my $legacy_filter
        = MT->registry(
        applications => cms => list_filters => $type => $legacy_id )
        or return;
    if ( my $cond = $legacy_filter->{condition} ) {
        $cond = MT->handler_to_coderef($cond);
        return unless $cond->();
    }
    my $label = $legacy_filter->{label};
    $label = $label->() if 'CODE' eq ref $label;
    my $hash = {
        id     => $legacy_id,
        label  => '(Legacy) ' . $label,
        legacy => 1,
        items  => [
            {   type => '__legacy',
                args => {
                    filter_key => $legacy_id,
                    ds         => $type,
                    filter_val => ( $app->param('filter_val') || '' ),
                    label      => "( $label )"
                },
            }
        ],
        can_edit   => 0,
        can_save   => 0,
        can_delete => 0,
    };
    for my $val ( values %$hash ) {
        $val = $val->() if 'CODE' eq ref $val;
    }
    $hash;
}

sub filters {
    my ( $app, $type ) = @_;
    my $obj_class    = MT->model($type);
    my @user_filters = MT->model('filter')
        ->load( { author_id => $app->user->id, object_ds => $type } );
    @user_filters = map { $_->to_hash } @user_filters;

    my @sys_filters;
    my $sys_filters = MT->registry( system_filters => $type );
    for my $sys_id ( keys %$sys_filters ) {
        next if $sys_id =~ /^_/;
        my $sys_filter = system_filter( $app, $type, $sys_id )
            or next;
        push @sys_filters, $sys_filter;
    }

    #FIXME: Is this always right path to get it?
    my @legacy_filters;
    my $legacy_filters
        = MT->registry( applications => cms => list_filters => $type );
    for my $legacy_id ( keys %$legacy_filters ) {
        next if $legacy_id =~ /^_/;
        my $legacy_filter = legacy_filter( $app, $type, $legacy_id )
            or next;
        push @legacy_filters, $legacy_filter;
    }

    my @filters = ( @user_filters, @sys_filters, @legacy_filters );
    for my $filter (@filters) {
        my $label = $filter->{label};
        if ( 'CODE' eq ref $label ) {
            $filter->{label} = $label->();
        }
    }
    return @filters;
}

1;
