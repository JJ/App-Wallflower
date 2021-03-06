use strict;
use warnings;
use Test::More;
use Path::Tiny ();
use List::Util qw( sum );
use URI;
use HTTP::Date qw( time2str );
use Wallflower;

# setup test data
my @tests;

# test data is an array ref containing:
# - quick description of the app
# - destination directory
# - the app itself
# - a list of test url for the app
#   as [ url, status, headers, file, content ]

push @tests, [
    'direct content',
    Path::Tiny->tempdir( CLEANUP => 1 ),
    sub {
        [   200,
            [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
            [ 'Hello,', ' ', 'World!' ]
        ];
    },
    [   '/' => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
        'index.html',
        'Hello, World!'
    ],
    [   URI->new('/index.htm') => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
        'index.htm',
        'Hello, World!'
    ],
    [   '/klonk/' => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
        Path::Tiny->new( 'klonk', 'index.html' ),
        'Hello, World!'
    ],
    [   '/clunk' => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
        'clunk', 'Hello, World!'
    ],
];

push @tests, [
    'content in a glob',
    Path::Tiny->tempdir( CLEANUP => 1 ),
    sub {
        [   200,
            [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
            do {
                my $file = Path::Tiny->new( $tests[0][1], 'index.html' );
                open my $fh, '<', $file or die "Can't open $file: $!";
                $fh;
                }
        ];
    },
    [   '/' => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
        'index.html',
        'Hello, World!'
    ],
];

push @tests, [
    'content in an object',
    Path::Tiny->tempdir( CLEANUP => 1 ),
    sub {
        [   200,
            [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
            do {

                package Clange;
                sub new { bless [ 'Hello,', ' ', 'World!' ] }
                sub getline { shift @{ $_[0] } }
                sub close   { }
                __PACKAGE__->new();
                }
        ];
    },
    [   '/' => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
        'index.html',
        'Hello, World!'
    ],
];

push @tests, [
    'status in the URL',
    Path::Tiny->tempdir( CLEANUP => 1 ),
    sub {
        my $env = shift;
        my ($status) = $env->{REQUEST_URI} =~ m{/(\d\d\d)$}g;
        $status ||= 404;
        [   $status,
            [   'Content-Type'   => 'text/plain',
                'Content-Length' => length $status
            ],
            [$status]
        ];
    },
    [   "/200" => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 3 ],
        '200', '200'
    ],
    [   "/403" => 403,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 3 ],
        '', ''
    ],
    [   "/blah" => 404,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 3 ],
        '', ''
    ],
];

push @tests, [
    'app that dies',
    Path::Tiny->tempdir( CLEANUP => 1 ),
    sub {die},
    [   '/' => 500,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 21 ], '', ''
    ],
];

my $last_modified = time2str( time - 10 );
push @tests, [
    'app supporting If-Modified-Since',
    Path::Tiny->tempdir( CLEANUP => 1 ),
    do {
        sub {
            my $env = shift;
            my $since = $env->{HTTP_IF_MODIFIED_SINCE} || '';
            return $last_modified eq $since
              ? [ 304, [], '' ]
              : [ 200,
                  [
                    'Content-Type'   => 'text/plain',
                    'Content-Length' => 13,
                    'Last-Modified'  => $last_modified,
                  ],
                  ['Hello, World!']
                ];
        };
    },
    [
        '/' => 200,
        [
            'Content-Type'   => 'text/plain',
            'Content-Length' => 13,
            'Last-Modified'  => $last_modified
        ],
        'index.html',
        'Hello, World!'
    ],
    [ '/' => 304, [], 'index.html', 'Hello, World!' ],
];

push @tests, [
    'not respecting directory semantics',
    Path::Tiny->tempdir( CLEANUP => 1 ),
    sub {
        [   200,
            [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
            [ 'Hello,', ' ', 'World!' ]
        ];
    },
    [ 'http://localhost//foo' => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
        'foo',
        'Hello, World!'
    ],
    [ 'http://localhost//foo/bar' => 999, [], '', '' ],
    [ '/foo' => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
        'foo',
        'Hello, World!'
    ],
    [ '/foo/bar' => 999, [], '', '' ],
    [ '/bar/foo' => 200,
        [ 'Content-Type' => 'text/plain', 'Content-Length' => 13 ],
        'bar/foo',
        'Hello, World!'
    ],
    [ '/bar' => 999, [], '', '' ],
];

plan tests => sum map 2 * ( @$_ - 3 ), @tests;

for my $t (@tests) {
    my ( $desc, $dir, $app, @urls ) = @$t;

    my $wf = Wallflower->new(
        application => $app,
        destination => $dir,
    );

    for my $u (@urls) {
        my ( $url, $status, $headers, $file, $content ) = @$u;

        my $result = $wf->get($url);
        is_deeply(
            $result,
            [   $status, $headers, $file && Path::Tiny->new( $dir, $file )
            ],
            "app ($desc) for $url"
        );

        if ( $status == 200 || $status == 304 ) {
            my $file_content
                = do { local $/; local @ARGV = ( $result->[2] ); <> };
            is( $file_content, $content, "content ($desc) for $url" );
        }
        else {
            is( $result->[2], '', "no file ($desc) for $url" );
        }
    }
}
