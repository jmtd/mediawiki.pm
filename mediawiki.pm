#!/usr/bin/perl
# By Scott Bronson.  Licensed under the GPLv2+ License.
# Extends Ikiwiki to be able to handle Mediawiki markup.
#
# To use the Mediawiki Plugin:
# - Install Text::MediawikiFormat
# - Turn of prefix_directives in your setup file.
#     (TODO: we probably don't need to do this anymore?)
#        prefix_directives => 1,
# - Add this plugin on Ikiwiki's path (perl -V, look for @INC)
#       cp mediawiki.pm something/IkiWiki/Plugin
# - And enable it in your setup file
#        add_plugins => [qw{mediawiki}],
# - Finally, turn off the link plugin in setup (this is important)
#        disable_plugins => [qw{link}],
# - Rebuild everything (actually, this should be automatic right?)
# - Now all files with a .mediawiki extension should be rendered properly.


package IkiWiki::Plugin::mediawiki;

use warnings;
use strict;
use IkiWiki 2.00;
use URI;


# This is a gross hack...  We disable the link plugin so that our
# linkify routine is always called.  Then we call the link plugin
# directly for all non-mediawiki pages.  Ouch...  Hopefully Ikiwiki
# will be updated soon to support multiple link plugins.
require IkiWiki::Plugin::link;

# Even if T:MwF is not installed, we can still handle all the linking.
# The user will just see Mediawiki markup rather than formatted markup.
eval q{use Text::MediawikiFormat ()};
my $markup_disabled = $@;

# Work around a UTF8 bug in Text::MediawikiFormat
# http://rt.cpan.org/Public/Bug/Display.html?id=26880
unless($markup_disabled) {
	no strict 'refs';
	no warnings;
	*{'Text::MediawikiFormat::uri_escape'} = \&URI::Escape::uri_escape_utf8;
}

my %metaheaders; 	# keeps track of redirects for pagetemplate.
my %tags;		# keeps track of tags for pagetemplate.


sub import { #{{{
	hook(type => "checkconfig", id => "mediawiki", call => \&checkconfig);
	hook(type => "scan", id => "mediawiki", call => \&scan);
	hook(type => "linkify", id => "mediawiki", call => \&linkify);
	hook(type => "htmlize", id => "mediawiki", call => \&htmlize);
	hook(type => "pagetemplate", id => "mediawiki", call => \&pagetemplate);
} # }}}


sub checkconfig
{
	return IkiWiki::Plugin::link::checkconfig(@_);
}


my $link_regexp = qr{
    \[\[(?=[^!])        # beginning of link
    ([^\n\r\]#|<>]+)      # 1: page to link to
    (?:
        \#              # '#', beginning of anchor
        ([^|\]]+)       # 2: anchor text
    )?                  # optional

    (?:
        \|              # followed by '|'
        ([^\]\|]*)      # 3: link text
    )?                  # optional
    \]\]                # end of link
        ([a-zA-Z]*)	# optional trailing alphas
}x;


# Convert spaces in the passed-in string into underscores.
# If passed in undef, returns undef without throwing errors.
sub underscorize
{
	my $var = shift;
	$var =~ tr{ }{_} if $var;
	return $var;
}


# Underscorize, strip leading and trailing space, and scrunch
# multiple runs of spaces into one underscore.
sub scrunch
{
	my $var = shift;
	if($var) {
		$var =~ s/^\s+|\s+$//g;		# strip leading and trailing space
		$var =~ s/\s+/ /g;		# squash multiple spaces to one
	}
	return $var;
}


# Translates Mediawiki paths into Ikiwiki paths.
# It needs to be pretty careful because Mediawiki and Ikiwiki handle
# relative vs. absolute exactly opposite from each other.
sub translate_path
{
	my $page = shift;
	my $path = scrunch(shift);

	# always start from root unless we're doing relative shenanigans.
	$page = "/" unless $path =~ /^(?:\/|\.\.)/;

	my @result = ();
	for(split(/\//, "$page/$path")) {
		if($_ eq '..') {
			pop @result;
		} else {
			push @result, $_ if $_ ne "";
		}
	}

	# temporary hack working around http://ikiwiki.info/bugs/Can__39__t_create_root_page/index.html?updated
	# put this back the way it was once this bug is fixed upstream.
	# This is actually a major problem because now Mediawiki pages can't link from /Git/git-svn to /git-svn.  And upstream appears to be uninterested in fixing this bug.  :(
	# return "/" . join("/", @result);
	return join("/", @result);
}


# Figures out the human-readable text for a wikilink
sub linktext
{
	my($page, $inlink, $anchor, $title, $trailing) = @_;
	my $link = translate_path($page,$inlink);

	# translate_path always produces an absolute link.
	# get rid of the leading slash before we display this link.
	$link =~ s#^/##;

	my $out = "";
	if($title) {
		 $out = IkiWiki::pagetitle($title);
	} else {
		$link = $inlink if $inlink =~ /^\s*\//;
	 	$out = $anchor ? "$link#$anchor" : $link;
		if(defined $title && $title eq "") {
			# a bare pipe appeared in the link...
			# user wants to strip namespace and trailing parens.
			$out =~ s/^[A-Za-z0-9_-]*://;
			$out =~ s/\s*\(.*\)\s*$//;
		}
		# A trailing slash suppresses the leading slash
		$out =~ s#^/(.*)/$#$1#;
	}
	$out .= $trailing if defined $trailing;
	return $out;
}


sub tagpage ($)
{
	my $tag=shift;

	if (exists $config{tagbase} && defined $config{tagbase}) {
		$tag=$config{tagbase}."/".$tag;
	}

	return $tag;
}


# Pass a URL and optional text associated with it.  This call turns
# it into fully-formatted HTML the same way Mediawiki would.
# Counter is used to number untitled links sequentially on the page.
# It should be set to 1 when you start parsing a new page.  This call
# increments it automatically.
sub generate_external_link
{
	my $url = shift;
	my $text = shift;
	my $counter = shift;

	# Mediawiki trims off trailing commas.
	# And apparently it does entity substitution first.
	# Since we can't, we'll fake it.

	# trim any leading and trailing whitespace
	$url =~ s/^\s+|\s+$//g;

	# url properly terminates on > but must special-case &gt;
	my $trailer = "";
	$url =~ s{(\&(?:gt|lt)\;.*)$}{ $trailer = $1, ''; }eg;

	# Trim some potential trailing chars, put them outside the link.
	my $tmptrail = "";
	$url =~ s{([,)]+)$}{ $tmptrail .= $1, ''; }eg;
	$trailer = $tmptrail . $trailer;

	my $title = $url;
	if(defined $text) {
		if($text eq "") {
			$text = "[$$counter]";
			$$counter += 1;
		}
		$text =~ s/^\s+|\s+$//g;
		$text =~ s/^\|//;
	} else {
		$text = $url;
	}

	return "<a href='$url' title='$title'>$text</a>$trailer";
}


# Called to handle bookmarks like [[#heading]] or <span class="createlink"><a href="http://u32.net/cgi-bin/ikiwiki.cgi?page=%20text%20&amp;from=Mediawiki_Plugin%2Fmediawiki&amp;do=create" rel="nofollow">?</a>#a</span>
sub generate_fragment_link
{
	my $url = shift;
	my $text = shift;

	my $inurl = $url;
	my $intext = $text;
	$url = scrunch($url);

	if(defined($text) && $text ne "") {
		$text = scrunch($text);
	} else {
		$text = $url;
	}

	$url = underscorize($url);

	# For some reason Mediawiki puts blank titles on all its fragment links.
	# I don't see why we would duplicate that behavior here.
	return "<a href='$url'>$text</a>";
}


sub generate_internal_link
{
	my($page, $inlink, $anchor, $title, $trailing, $proc) = @_;

	# Ikiwiki's link link plugin wrecks this line when displaying on the site.
	# Until the code highlighter plugin can turn off link finding,
	# always escape double brackets in double quotes: [[
	if($inlink eq '..') {
		# Mediawiki doesn't touch links like [[..#hi|ho]].
		return "[[" . $inlink . ($anchor?"#$anchor":"") .
			($title?"|$title":"") . "]]" . $trailing;
	}

	my($linkpage, $linktext);
	if($inlink =~ /^ (:?) \s* Category (\s* \: \s*) ([^\]]*) $/x) {
		# Handle category links
		my $sep = $2;
		$inlink = $3;
		$linkpage = IkiWiki::linkpage(translate_path($page, $inlink));
		if($1) {
			# Produce a link but don't add this page to the given category.
			$linkpage = tagpage($linkpage);
			$linktext = ($title ? '' : "Category$sep") .
				linktext($page, $inlink, $anchor, $title, $trailing);
			$tags{$page}{$linkpage} = 1;
		} else {
			# Add this page to the given category but don't produce a link.
			$tags{$page}{$linkpage} = 1;
			&$proc(tagpage($linkpage), $linktext, $anchor);
			return "";
		}
	} else {
		# It's just a regular link
		$linkpage = IkiWiki::linkpage(translate_path($page, $inlink));
		$linktext = linktext($page, $inlink, $anchor, $title, $trailing);
	}

	return &$proc($linkpage, $linktext, $anchor);
}


sub check_redirect
{
	my %params=@_;

	my $page=$params{page};
	my $destpage=$params{destpage};
	my $content=$params{content};

	return "" if $page ne $destpage;

	if($content !~ /^ \s* \#REDIRECT \s* \[\[ ( [^\]]+ ) \]\]/x) {
		# this page isn't a redirect, render it normally.
		return undef;
	}

	# The rest of this function is copied from the redir clause
	# in meta::preprocess and actually handles the redirect.

	my $value = $1;
	$value =~ s/^\s+|\s+$//g;

	my $safe=0;
	if ($value !~ /^\w+:\/\//) {
		# it's a local link
		my ($redir_page, $redir_anchor) = split /\#/, $value;

		add_depends($page, $redir_page);
		my $link=bestlink($page, underscorize(translate_path($page,$redir_page)));
		if (! length $link) {
			return "<b>Redirect Error:</b> <nowiki>[[$redir_page]] not found.</nowiki>";
		}

		$value=urlto($link, $page);
		$value.='#'.$redir_anchor if defined $redir_anchor;
		$safe=1;

		# redir cycle detection
		$pagestate{$page}{mediawiki}{redir}=$link;
		my $at=$page;
		my %seen;
		while (exists $pagestate{$at}{mediawiki}{redir}) {
			if ($seen{$at}) {
				return "<b>Redirect Error:</b> cycle found on <nowiki>[[$at]]</nowiki>";
			}
			$seen{$at}=1;
			$at=$pagestate{$at}{mediawiki}{redir};
		}
	} else {
		# it's an external link
		$value = encode_entities($value);
	}

	my $redir="<meta http-equiv=\"refresh\" content=\"0; URL=$value\" />";
	$redir=scrub($redir) if !$safe;
	push @{$metaheaders{$page}}, $redir;

	return "Redirecting to $value ...";
}


# Feed this routine a string containing <nowiki>...</nowiki> sections,
# this routine calls your callback for every section not within nowikis,
# collecting its return values and returning the rewritten string.
sub skip_nowiki
{
	my $content = shift;
	my $proc = shift;

	my $result = "";
	my $state = 0;

	for(split(/(<nowiki[^>]*>.*?<\/nowiki\s*>)/s, $content)) {
		$result .= ($state ? $_ : &$proc($_));
		$state = !$state;
	}

	return $result;
}


# Converts all links in the page, wiki and otherwise.
sub linkify (@)
{
	my %params=@_;

	my $page=$params{page};
	my $destpage=$params{destpage};
	my $content=$params{content};

	my $file=$pagesources{$page};
	my $type=pagetype($file);
	my $counter = 1;

	if($type ne 'mediawiki') {
		return IkiWiki::Plugin::link::linkify(@_);
	}

	my $redir = check_redirect(%params);
	return $redir if defined $redir;

	# this code was copied from MediawikiFormat.pm.
	# Heavily changed because MF.pm screws up escaping when it does
	# this awful hack: $uricCheat =~ tr/://d;
	my $schemas = [qw(http https ftp mailto gopher)];
	my $re = join "|", map {qr/\Q$_\E/} @$schemas;
	my $schemes = qr/(?:$re)/;
	# And this is copied from URI:
	my $reserved   = q(;/?@&=+$,);	# NOTE: no colon or [] !
	my $uric       = quotemeta($reserved) . $URI::unreserved . "%#";

	my $result = skip_nowiki($content, sub {
		$_ = shift;

		# Escape any anchors
		#s/<(a[\s>\/])/&lt;$1/ig;
		# Disabled because this appears to screw up the aggregate plugin.
		# I guess we'll rely on Iki to post-sanitize this sort of stuff.

		# Replace external links, http://blah or [http://blah]
		s{\b($schemes:[$uric][:$uric]+)|\[($schemes:[$uric][:$uric]+)([^\]]*?)\]}{
			generate_external_link($1||$2, $3, \$counter)
		}eg;

		# Handle links that only contain fragments.
		s{ \[\[ \s* (\#[^|\]'"<>&;]+) (?:\| ([^\]'"<>&;]*))? \]\] }{
			generate_fragment_link($1, $2)
		}xeg;

		# Match all internal links
		s{$link_regexp}{
			generate_internal_link($page, $1, $2, $3, $4, sub {
				my($linkpage, $linktext, $anchor) = @_;
				return htmllink($page, $destpage, $linkpage,
					linktext => $linktext,
					anchor => underscorize(scrunch($anchor)));
			});
		}eg;
	
		return $_;
	});

	return $result;
}


# Find all WikiLinks in the page.
sub scan (@)
{
	my %params = @_;
	my $page=$params{page};
	my $content=$params{content};

	my $file=$pagesources{$page};
	my $type=pagetype($file);

	if($type ne 'mediawiki') {
		return IkiWiki::Plugin::link::scan(@_);
	}

	skip_nowiki($content, sub {
		$_ = shift;
		while(/$link_regexp/g) {
			generate_internal_link($page, $1, '', '', '', sub {
				my($linkpage, $linktext, $anchor) = @_;
				push @{$links{$page}}, $linkpage;
				return undef;
			});
		}
		return '';
	});
}


# Convert the page to HTML.
sub htmlize (@)
{
	my %params=@_;
	my $page = $params{page};
	my $content = $params{content};


	return $content if $markup_disabled;

	# Do a little preprocessing to babysit Text::MediawikiFormat
	# If a line begins with tabs, T:MwF won't convert it into preformatted blocks.
	$content =~ s/^\t/    /mg;

	my $ret = Text::MediawikiFormat::format($content, {

	    allowed_tags    => [#HTML
                # MediawikiFormat default
                qw(b big blockquote br caption center cite code dd
                   div dl dt em font h1 h2 h3 h4 h5 h6 hr i li ol p
                   pre rb rp rt ruby s samp small strike strong sub
                   sup table td th tr tt u ul var),
                 # Mediawiki Specific
                 qw(nowiki),
                 # Our additions
                 qw(del ins),	# These should have been added all along.
                 qw(span),	# Mediawiki allows span but that's rather scary...?
                 qw(a),		# this is unfortunate; should handle links after rendering the page.
		 # also unfortunate
		 qw(img)
               ],

	    allowed_attrs   => [
                qw(title align lang dir width height bgcolor),
                qw(clear), # BR
                qw(noshade), # HR
                qw(cite), # BLOCKQUOTE, Q
                qw(size face color), # FONT
                # For various lists, mostly deprecated but safe
                qw(type start value compact),
                # Tables
                qw(summary width border frame rules cellspacing
                   cellpadding valign char charoff colgroup col
                   span abbr axis headers scope rowspan colspan),
                qw(id class name style), # For CSS
                # Our additions
                qw(href),
		# img tags
		qw(src alt width height class)
               ],

	   }, {
		extended => 0,
		absolute_links => 0,
		implicit_links => 0
	   });

	return $ret;
}


# This is only needed to support the check_redirect call.
sub pagetemplate (@)
{
	my %params = @_;
	my $page = $params{page};
	my $destpage = $params{destpage};
	my $template = $params{template};

	# handle metaheaders for redirects
	if (exists $metaheaders{$page} && $template->query(name => "meta")) {
	# avoid duplicate meta lines
		my %seen;
		$template->param(meta => join("\n", grep { (! $seen{$_}) && ($seen{$_}=1) } @{$metaheaders{$page}}));
	}

	$template->param(tags => [
		map {
			link => htmllink($page, $destpage, tagpage($_), rel => "tag")
		}, sort keys %{$tags{$page}}
	]) if exists $tags{$page} && %{$tags{$page}} && $template->query(name => "tags");

	# It's an rss/atom template. Add any categories.
	if ($template->query(name => "categories")) {
		if (exists $tags{$page} && %{$tags{$page}}) {
			$template->param(categories => [map { category => $_ },
				sort keys %{$tags{$page}}]);
		}
	}
}

1

