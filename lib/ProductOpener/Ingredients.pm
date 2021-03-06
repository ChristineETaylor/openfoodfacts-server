# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2018 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package ProductOpener::Ingredients;

use utf8;
use Modern::Perl '2012';
use Exporter    qw< import >;

BEGIN
{
	use vars       qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
	@EXPORT = qw();            # symbols to export by default
	@EXPORT_OK = qw(
					&extract_ingredients_from_image
					&extract_ingredients_from_text
					
					&extract_ingredients_classes_from_text
					
					&detect_allergens_from_text

	
					);	# symbols to export on request
	%EXPORT_TAGS = (all => [@EXPORT_OK]);
}

use vars @EXPORT_OK ;
use experimental 'smartmatch';

use ProductOpener::Store qw/:all/;
use ProductOpener::Config qw/:all/;
use ProductOpener::Users qw/:all/;
use ProductOpener::Products qw/:all/;
use ProductOpener::TagsEntries qw/:all/;
use ProductOpener::Tags qw/:all/;
use ProductOpener::URL qw/:all/;


use Image::OCR::Tesseract 'get_ocr';
use Encode;
use Clone qw(clone);

use LWP::UserAgent;
use Encode;
use JSON::PP;

# MIDDLE DOT with common substitutes (BULLET variants, BULLET OPERATOR and DOT OPERATOR (multiplication))
my $middle_dot = qr/(?:\N{U+00B7}|\N{U+2022}|\N{U+2023}|\N{U+25E6}|\N{U+2043}|\N{U+204C}|\N{U+204D}|\N{U+2219}|\N{U+22C5})/i;
# Unicode category 'Punctuation, Dash', SWUNG DASH and MINUS SIGN
my $dashes = qr/(?:\p{Pd}|\N{U+2053}|\N{U+2212})/i;
my $separators = qr/(\.\s|,|;|:|$middle_dot|\[|\{|\(|( $dashes ))|(\/)/i;
# separators include the dot . followed by a space, but we don't want to separate 1.4 etc.
my $separators_except_comma = qr/(;|:|$middle_dot|\[|\{|\(|( $dashes ))|(\/)/i;

# load ingredients classes

opendir(DH, "$data_root/ingredients") or print STDERR "cannot open directory $data_root/ingredients: $!\n";

foreach my $f (readdir(DH)) {
	next if $f eq '.';
	next if $f eq '..';
	next if ($f !~ /\.txt$/);
	
	my $class = $f;
	$class =~ s/\.txt$//;
	
	$ingredients_classes{$class} = {};
	
	open(my $IN, "<:encoding(UTF-8)", "$data_root/ingredients/$f");
	while (<$IN>) {
		chomp;
		next if /^\#/;
		my ($canon_name, $other_names, $misc, $desc, $level, $warning) = split("\t");
		my $id = get_fileid($canon_name);
		next if (not defined $id) or ($id eq '');
		(not defined $level) and $level = 0;
		
		# additives: always set level to 0 right now, until we have a better list
		$level = 0;
		
		if (not defined $ingredients_classes{$class}{$id}) {
			# E322 before E322(i) : E322 should be associated with "lecithine"
			$ingredients_classes{$class}{$id} = {name=>$canon_name, id=>$id, other_names=>$other_names, level=>$level, description=>$desc, warning=>$warning};
		}
		#print STDERR "name: $canon_name\nother_names: $other_names\n";
		if (defined $other_names) {
			foreach my $other_name (split(/,/, $other_names)) {
				$other_name =~ s/^\s+//;
				$other_name =~ s/\s+$//;
				my $other_id = get_fileid($other_name);
				next if $other_id eq '';
				next if $other_name eq '';
				if (not defined $ingredients_classes{$class}{$other_id}) { # Take the first one
					$ingredients_classes{$class}{$other_id} = {name=>$other_name, id=>$id};
					#print STDERR "$id\t$other_id\n";
				}
			}
		}
	}
	close $IN;
	
	$ingredients_classes_sorted{$class} = [sort keys %{$ingredients_classes{$class}}];
}
closedir(DH);



sub extract_ingredients_from_image($$$) {

	my $product_ref = shift;
	my $id = shift;
	my $ocr_engine = shift;
	
	my $path = product_path($product_ref->{code});
	my $status = 1;
	
	my $filename = '';
	
	my $lc = $product_ref->{lc};
	
	if ($id =~ /^ingredients_(\w\w)$/) {
		$lc = $1;
	}
	else {
		$id = "ingredients";
	}
	
	my $size = 'full';
	if ((defined $product_ref->{images}) and (defined $product_ref->{images}{$id})
		and (defined $product_ref->{images}{$id}{sizes}) and (defined $product_ref->{images}{$id}{sizes}{$size})) {
		$filename = $id . '.' . $product_ref->{images}{$id}{rev} ;
	}
	
	my $image = "$www_root/images/products/$path/$filename.full.jpg";
	my $image_url = format_subdomain('static') . "/images/products/$path/$filename.full.jpg";
	
	my $text;
	
	print STDERR "Ingredients.pm - extracts_ingredients_from_image - id: $id - ocr_engine: $ocr_engine\n";
	
	if ($ocr_engine eq 'tesseract') {
	
		my $lan;
		
		if (defined $ProductOpener::Config::tesseract_ocr_available_languages{$lc}) {
			$lan = $ProductOpener::Config::tesseract_ocr_available_languages{$lc};
		}
		elsif (defined $ProductOpener::Config::tesseract_ocr_available_languages{$product_ref->{lc}}) {
			$lan = $ProductOpener::Config::tesseract_ocr_available_languages{$product_ref->{lc}};
		}	
		elsif (defined $ProductOpener::Config::tesseract_ocr_available_languages{en}) {
			$lan = $ProductOpener::Config::tesseract_ocr_available_languages{en};
		}
		
		print STDERR "extract_ingredients_from_image - lc: $lc - lan: $lan - id: $id - image: $image\n";
		
		if (defined $lan) {
			$text =  decode utf8=>get_ocr($image,undef,$lan);
			
			if ((defined $text) and ($text ne '')) {
				$product_ref->{ingredients_text_from_image} = $text;
				$status = 0;
			}
		}
		else {
			print STDERR "extract_ingredients_from_image - lc: $lc - lan: $lan - id: $id - no available tesseract dictionary\n";	
		}
	
	}
	elsif ($ocr_engine eq 'google_cloud_vision') {

		my $url = "https://alpha-vision.googleapis.com/v1/images:annotate?key=" . $ProductOpener::Config::google_cloud_vision_api_key;
		# alpha-vision.googleapis.com/

		my $ua = LWP::UserAgent->new();

		my $api_request_ref = 		 
			{
				requests => 
					[ 
						{
							features => [{ type => 'TEXT_DETECTION'}], image => { source => { imageUri => $image_url}}
						}
					]
			}
		;
		my $json = encode_json($api_request_ref);
						
		my $request = HTTP::Request->new(POST => $url);
		$request->header( 'Content-Type' => 'application/json' );
		$request->content( $json );

		my $res = $ua->request($request);
			
		if ($res->is_success) {
		
			print STDERR "google cloud vision: success\n";
		
			my $json_response = $res->decoded_content;
			
			my $cloudvision_ref = decode_json($json_response);
			
			my $json_file = "$www_root/images/products/$path/$filename.full.jpg" . ".google_cloud_vision.json";
			
			print STDERR "google cloud vision: saving json response to $json_file\n";
			
			open (my $OUT, ">:encoding(UTF-8)", $json_file);
			print $OUT $json_response;
			close $OUT;			
			
			if ((defined $cloudvision_ref->{responses}) and (defined $cloudvision_ref->{responses}[0])
				and (defined $cloudvision_ref->{responses}[0]{fullTextAnnotation})
				and (defined $cloudvision_ref->{responses}[0]{fullTextAnnotation}{text})) {
				
				print STDERR "google cloud vision: found a text response\n";
	
				
				$product_ref->{ingredients_text_from_image} = $cloudvision_ref->{responses}[0]{fullTextAnnotation}{text};
				$status = 0;
			}
			
		}
		else {
			print STDERR "google cloud vision: not ok - code: " . $res->code . " - message: " . $res->message . "\n";
		}

	
	}
	
	
	return $status;

}


sub extract_ingredients_from_text($) {

	my $product_ref = shift;
	my $path = product_path($product_ref->{code});
	my $text = $product_ref->{ingredients_text};
	
	print STDERR "extract_ingredients_from_text - text: $text \n";
	
	# unify newline feeds to \n
	$text =~ s/\r\n/\n/g;
	$text =~ s/\R/\n/g;
	
	# remove ending .
	$text =~ s/(\s|\.)+$//;
	

	
	# $product_ref->{ingredients_tags} = ["first-ingredient", "second-ingredient"...]
	# $product_ref->{ingredients}= [{id =>, text =>, percent => etc. }, ] # bio / équitable ? 
	
	$product_ref->{ingredients} = [];
	$product_ref->{'ingredients_tags'} = [];

	# farine (12%), chocolat (beurre de cacao (15%), sucre [10%], protéines de lait, oeuf 1%) - émulsifiants : E463, E432 et E472 - correcteurs d'acidité : E322/E333 E474-E475, acidifiant (acide citrique, acide phosphorique) - sel : 1% ...
	
	my @ranked_ingredients = ();
	my @unranked_ingredients = ();
	my $level = 0;
	
	# transform 0,2% into 0.2%
	$text =~ s/(\d),(\d+)( )?\%/$1.$2\%/g;
	$text =~ s/—/-/g;
	
	# assume commas between numbers are part of the name
	# e.g. en:2-Bromo-2-Nitropropane-1,3-Diol, Bronopol
	# replace by a lower comma ‚

	$text =~ s/(\d),(\d)/$1‚$2/g;		
	
	my $analyze_ingredients = sub($$$$$) {
		my $analyze_ingredients_self = shift;
		my $ranked_ingredients_ref = shift;
		my $unranked_ingredients_ref = shift;
		my $level = shift;
		my $s = shift;
		
		# print STDERR "analyze_ingredients level $level: $s\n";
		
		my $last_separator =  undef; # default separator to find the end of "acidifiants : E330 - E472"
		
		my $after = '';
		my $before = '';
		my $between = '';
		my $between_level = $level;
		my $percent = undef;
		
		# find the first separator or ( or [ or : 
		if ($s =~ $separators) {
		
			$before = $`;
			my $sep = $1;
			$after = $';
			
			# print STDERR "separator: $sep\tbefore: $before\tafter: $after\n";
			
			if ($sep =~ /(:|\[|\{|\()/i) {
			
				my $ending = $last_separator;
				if (not defined $ending) {
					$ending = ",|-";
				}
				if ($sep eq '(') {
					$ending = '\)';
				}
				elsif ($sep eq '[') {
					$ending = '\]';
				}
				elsif ($sep eq '{') {
					$ending = '\}';
				}				
				$ending .= '|$';
				$ending = '(' . $ending . ')';
				
				# print STDERR "special separator: $sep - ending: $ending - after: $after\n";
				
				# another separator before the ending separator ? we probably have several sub-ingredients
				if ($after =~ /^(.*?)$ending/i) {
					$between = $1;
					$after = $';
					
					# print STDERR "sub-ingredients - between: $between - after: $after\n";
					
					if ($between =~ $separators) {
						$between_level = $level + 1;
					}
					else {
						# no separator found : 34% ? or single ingredient
						if ($between =~ /^\s*(\d+((\,|\.)\d+)?)\s*\%\s*$/) {
							# print STDERR "percent found:  $1\%\n";
							$percent = $1;
							$between = '';
						}
						else {
							# single ingredient, stay at same level
							# print STDERR "single ingredient, stay at same level\n";
						}
					}
				}
				else {
					# print STDERR "could not find ending separator: $ending - after: $after\n"
					# ! could not find the ending separator
				}
			
			}
			else {
				# simple separator
				$last_separator = $sep;
			}
			
			if ($after =~ /^\s*(\d+((\,|\.)\d+)?)\s*\%\s*(\),\],\])*($separators|$)/) {
				# print STDERR "percent found: $after = $1 + $'\%\n";
				$percent = $1;
				$after = $';
			}		
		}
		else {
			# no separator found: only one ingredient
			# print STDERR "no separator found: $s\n";
			$before = $s;
		}
		
		# remove ending parenthesis
		$before =~ s/(\),\],\])*//;
		
		# Strawberry 10.3%
		if ($before =~ /\s*(\d+((\,|\.)\d+)?)\s*\%\s*(\),\],\])*$/) {
			# print STDERR "percent found: $before = $` + $1\%\n";
			$percent = $1;
			$before = $`;
		}		
		
		# 90% boeuf, 100% pur jus de fruit, 45% de matière grasses
		if ($before =~ /^\s*(\d+((\,|\.)\d+)?)\s*\%\s*(pur|de|d')?\s*/i) {
			# print STDERR "'x% something' : percent found: $before = $' + $1\%\n";
			$percent = $1;
			$before = $';
		}		
		
		
		
		my $ingredient = $before;
		chomp($ingredient);
		$ingredient =~ s/\s+$//;
		$ingredient =~ s/^\s+//;
		
		# remove percent
		
		# remove * and other chars before and after the name of ingredients
		$ingredient =~ s/(\s|\*|\)|\]|\}|\.|-|')+$//;
		$ingredient =~ s/^(\s|\*|\)|\]|\}|\.|-|')+//;
		
		$ingredient =~ s/\s*(\d+(\,\.\d+)?)\s*\%\s*$//;
		
		my %ingredient = (
			id => get_fileid($ingredient),
			text => $ingredient
		);
		if (defined $percent) {
			$ingredient{percent} = $percent;
		}
		

		
		if ($ingredient ne '') {
		
			# ingredients tags that are too long (greater than 1024, mongodb max index key size)
			# will cause issues for the mongodb ingredients_tags index, just drop them
			
			if (length($ingredient{id}) < 500) {
				if ($level == 0) {
					push @$ranked_ingredients_ref, \%ingredient;
				}
				else {
					push @$unranked_ingredients_ref, \%ingredient;
				}
			}
		}
		
		if ($between ne '') {
			$analyze_ingredients_self->($analyze_ingredients_self, $ranked_ingredients_ref, $unranked_ingredients_ref , $between_level, $between);
		}
		
		if ($after ne '') {
			$analyze_ingredients_self->($analyze_ingredients_self, $ranked_ingredients_ref, $unranked_ingredients_ref , $level, $after);
		}		
		
	};
	
	$analyze_ingredients->($analyze_ingredients, \@ranked_ingredients, \@unranked_ingredients , 0, $text);
	
	for (my $i = 0; $i <= $#ranked_ingredients; $i++) {
		$ranked_ingredients[$i]{rank} = $i + 1;
	}
	
	foreach my $ingredient (@ranked_ingredients, @unranked_ingredients) {
		push @{$product_ref->{ingredients}}, $ingredient;
		push @{$product_ref->{ingredients_tags}}, $ingredient->{id};
	}
	
	my $field = "ingredients";
	if (defined $taxonomy_fields{$field}) {
		$product_ref->{$field . "_hierarchy" } = [ gen_ingredients_tags_hierarchy_taxonomy($product_ref->{lc}, join(", ", @{$product_ref->{ingredients_tags}} )) ];
		$product_ref->{$field . "_tags" } = [];
		my $unknown = 0;
		foreach my $tag (@{$product_ref->{$field . "_hierarchy" }}) {
			my $tagid = get_taxonomyid($tag);
			push @{$product_ref->{$field . "_tags" }}, $tagid;
			if (not exists_taxonomy_tag("ingredients", $tagid)) {
				$unknown++;
			}
		}
		$product_ref->{"unknown_ingredients_n" } = $unknown;
	}
	
	
	if ($product_ref->{ingredients_text} ne "") {
	
		$product_ref->{ingredients_n} = scalar @{$product_ref->{ingredients_tags}};
	
		my $d = int(($product_ref->{ingredients_n} - 1 ) / 10);
		my $start = $d * 10 + 1;
		my $end = $d * 10 + 10;
	
		$product_ref->{ingredients_n_tags} = [$product_ref->{ingredients_n} . "", "$start" . "-" . "$end"];
	}
	else {
		delete $product_ref->{ingredients_n};
		delete $product_ref->{ingredients_n_tags};
	}
}


# function to normalize strings like "Carbonate d'ammonium" in French
# x is the prefix
# y can contain de/d' (of in French)
sub normalize_fr_a_de_b($$) {

	my $a = shift;
	my $b = shift;
	
	$a =~ s/\s+$//;
	$b =~ s/^\s+//;

	$b =~ s/^(de |d')//;
	
	if ($b =~ /^(a|e|i|o|u|y|h)/i) {
		return $a . " d'" . $b;
	}
	else {
		return $a . " de " . $b;
	}
}

sub normalize_fr_a_de_enumeration {

	my $a = shift;
	
	return join(",", map { normalize_fr_a_de_b($a, $_)} @_);
}


# iodure et hydroxide de potassium
sub normalize_fr_a_et_b_de_c($$$) {

	my $a = shift;
	my $b = shift;
	my $c = shift;
	
	return normalize_fr_a_de_b($a, $c) . "," . normalize_fr_a_de_b($b, $c);
}


sub normalize_fr_vitamin($) {

	my $a = shift;

	print STDERR "norm vitamin - ->$a<-\n";
	
	$a =~ s/\s+$//;
	$a =~ s/^\s+//;


	
	# does it look like a vitamin code?
	if ($a =~ /^[a-z][a-z]?-? ?\d?\d?$/i) {
		return "vitamine $a";
	}
	else {
		return $a;
	}
}

sub normalize_fr_vitamins_enumeration($) {
	
	my $vitamins_list = shift;
	
	my @vitamins = split(/\(|\)|\/| \/ | - |, |,| et /, $vitamins_list);
	
	print STDERR "split_vitamins input: " . $vitamins_list . "\n";
	
	
	# first output "vitamines," so that the current additive class is set to "vitamins"
	my $split_vitamins_list = "vitamines," . join(",", map { normalize_fr_vitamin($_)} @vitamins);
	print STDERR "split_vitamins output: " . $split_vitamins_list . "\n";
	return $split_vitamins_list;
}


sub extract_ingredients_classes_from_text($) {

	my $product_ref = shift;
	my $path = product_path($product_ref->{code});
	my $text = $product_ref->{ingredients_text};
	my $lc = $product_ref->{lc};

	# vitamins...
	# vitamines A, B1, B2, B5, B6, B9, B12, C, D, H, PP et E (lactose, protéines de lait)
	
	my $split_vitamins = sub ($$) {
		my $vitamin = shift;
		my $list = shift;
		
		my $return = '';
		foreach my $vitamin_code (split (/(\W|\s|-|n|;|et|and)+/, $list)) {
			 next if $vitamin_code =~ /^(\W|\s|-|n|;|et|and)*$/;
			$return .= $vitamin . " " . $vitamin_code . " - ";
		}
		return $return;
	};
	
	# vitamin code: 1 or 2 letters followed by 1 or 2 numbers (e.g. PP, B6, B12)
	# $text =~ s/(vitamin|vitamine)(s?)(((\W+)((and|et) )?(\w(\w)?(\d+)?)\b)+)/$split_vitamins->($1,$3)/eig;
	
	# 2018-03-07 : commenting out the code above as we are now separating vitamins from additives,
	# and PP, B6, B12 etc. will be listed as synonyms for Vitamine PP, Vitamin B6, Vitamin B12 etc.
	# we will need to be careful that we don't match a single letter K, E etc. that is not a vitamin, and if it happens, check for a "vitamin" prefix
		
		
		
	# in India: INS 240 instead of E 240, bug #1133)
	$text =~ s/\bins( |-)?(\d)/E$2/ig;
	
	# E 240, E.240, E-240..
	# E250-E251-E260
	#$text =~ s/(\b|-)e( |-|\.)?(\d+)( )?([a-z])??(i|ii|iii|iv|v|vi|vii|viii|ix|x|xi|xii|xii|xiv|xv)?(\b|-)/$1 - e$3$5 - $7/ig;
	# add separations between all E340... "colorants naturels : rose E120, verte E161b, blanche : sans colorant"
	#$text =~ s/(\b|-)e( |-|\.)?(\d+)( )?([a-z])??(i|ii|iii|iv|v|vi|vii|viii|ix|x|xi|xii|xii|xiv|xv)?(\b|-)/$1 - e$3$5 - $7/ig;
	#$text =~ s/(\b|-)e( |-|\.)?(\d+)( )?([a-z])?(i|ii|iii|iv|v|vi|vii|viii|ix|x|xi|xii|xii|xiv|xv)?(\b|-)/$1 - e$3$5 - $7/ig;
	# ! [a-z] matches i... replacing in line above -- 2015/08/12
	$text =~ s/(\b|-)e( |-|\.)?(\d+)( )?([abcdefgh])?(\))?(i|ii|iii|iv|v|vi|vii|viii|ix|x|xi|xii|xii|xiv|xv)?(\))?(\b|-)/$1 - e$3$5$7 - $9/ig;
	
	# ! caramel E150d -> caramel - E150d -> e150a - e150d ...
	$text =~ s/(caramel|caramels)(\W*)e150/e150/ig;
	# e432 et lécithines -> e432 - et lécithines
	$text =~ s/ - et / - /ig;
	
	# stabilisant e420 (sans : )
	$text =~ s/(conservateur|acidifiant|stabilisant|colorant|antioxydant|antioxygène|antioxygene|edulcorant|édulcorant|d'acidité|d'acidite|de goût|de gout|émulsifiant|emulsifiant|gélifiant|gelifiant|epaississant|épaississant|à lever|a lever|de texture|propulseur|emballage|affermissant|antiagglomérant|antiagglomerant|antimoussant|de charges|de fonte|d'enrobage|humectant|sequestrant|séquestrant|de traitement de la farine|de traitement)(s)?(\s)?(:)?/$1$2 : /ig;
	# citric acid natural flavor (may be a typo)
	$text =~ s/(natural flavor)(s)?(\s)?(:)?/: $1$2 : /ig;
	
	# mono-glycéride -> monoglycérides
	$text =~ s/(mono|di)-([a-z])/$1$2/ig;
	$text =~ s/\bmono /mono- /ig;
	# acide gras -> acides gras
	$text =~ s/acide gras/acides gras/ig;
	$text =~ s/glycéride /glycérides /ig;
	
	# !! mono et diglycérides ne doit pas donner mono + diglycérides : keep the whole version too.
	# $text =~ s/(,|;|:|\)|\(|( - ))(.+?)( et )(.+?)(,|;|:|\)|\(|( - ))/$1$3_et_$5$6 , $1$3 et $5$6/ig;
	
	# print STDERR "additives: $text\n\n";
	
	$product_ref->{ingredients_text_debug} = $text;	
	

	if ($lc eq 'fr') {
	
		# huiles de palme et de
		
		# carbonates d'ammonium et de sodium
		
		# carotène et extraits de paprika et de curcuma
		
		# Minéraux (carbonate de calcium, chlorures de calcium, potassium et magnésium, citrates de potassium et de sodium, phosphate de calcium,
		# sulfates de fer, de zinc, de cuivre et de manganèse, iodure de potassium, sélénite de sodium).
		
		
		# simple plural (just an additional "s" at the end) will be added in the regexp
		my @prefixes = (
"extrait",
"huile",
"huile végétale",
"huiles végétales",
"matière grasse",
"matières grasses",
"graisses",
"lécithine",

"carbonate",
"chlorure",
"citrate",
"iodure",
"nitrate",
"phosphate",
"sélénite",
"sulfate",
"hydroxyde",
"sulphate",
	);
	
		my @suffixes = (
"curcuma",
"romarin",
	
"colza",
"palme",
"tournesol",

"aluminium",
"ammonium",
"calcium",
"citrate",
"cuivre",
"fer",
"magnésium",
"manganèse",
"potassium",
"sodium",
"zinc",
);


		my $prefixregexp = "";
		foreach my $prefix (@prefixes) {
			$prefixregexp .= '|' . $prefix . '|' . $prefix . 's';
			my $unaccented_prefix = unac_string_perl($prefix);
			if ($unaccented_prefix ne $prefix) {
				$prefixregexp .= '|' . $unaccented_prefix . '|' . $unaccented_prefix . 's';
			}
			
		}
		$prefixregexp =~ s/^\|//;
		
		

		my $suffixregexp = "";
		foreach my $suffix (@suffixes) {
			$suffixregexp .= '|' . $suffix . '|' . $suffix . 's';
			my $unaccented_suffix = unac_string_perl($suffix);
			if ($unaccented_suffix ne $suffix) {
				$suffixregexp .= '|' . $unaccented_suffix . '|' . $unaccented_suffix . 's';
			}
			
		}
		$suffixregexp =~ s/^\|//;		
		
		$text =~ s/($prefixregexp) et ($prefixregexp) (de |d')?($suffixregexp)/normalize_fr_a_et_b_de_c($1, $2, $4)/ieg;
		
		$text =~ s/($prefixregexp) (de |d')?($suffixregexp) et (de |d')?($suffixregexp)/normalize_fr_a_de_enumeration($1, $3, $5)/ieg;
		$text =~ s/($prefixregexp) (de |d')?($suffixregexp), (de |d')?($suffixregexp) et (de |d')?($suffixregexp)/normalize_fr_a_de_enumeration($1, $3, $5, $7)/ieg;
		$text =~ s/($prefixregexp) (de |d')?($suffixregexp), (de |d')?($suffixregexp), (de |d')?($suffixregexp) et (de |d')?($suffixregexp)/normalize_fr_a_de_enumeration($1, $3, $5, $7, $9)/ieg;
		$text =~ s/($prefixregexp) (de |d')?($suffixregexp), (de |d')?($suffixregexp), (de |d')?($suffixregexp), (de |d')?($suffixregexp) et (de |d')?($suffixregexp)/normalize_fr_a_de_enumeration($1, $3, $5, $7, $9, $11)/ieg;
		
		# Phosphate d'aluminium et de sodium --> E541. Should not be split.
		
		$text =~ s/(phosphate|phosphates) d'aluminium,?(phosphate|phosphates) de sodium/phosphate d'aluminium et de sodium/ig;
		
		# Sels de sodium et de potassium de complexes cupriques de chlorophyllines -> should not be split... 
		$text =~ s/(sel|sels) de sodium,(sel|sels) de potassium/sels de sodium et de potassium/ig;
	
		# vitamines A, B1, B2, B5, B6, B9, B12, C, D, H, PP et E
		# vitamines (A, B1, B2, B5, B6, B9, B12, C, D, H, PP et E)

		
		my @vitaminssuffixes = (
"a", "rétinol",
"b", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8", "b9", "b10", "b11", "b12",
"thiamine",
"riboflavine",
"niacine",
"pyridoxine",
"cobalamine",
"biotine",
"acide pantothénique",
"acide folique",
"c", "acide ascorbique",
"d", "d2", "d3", "cholécalciférol",
"e", "tocophérol", "alphatocophérol", "alpha-tocophérol",
"f",
"h",
"k", "k1", "k2", "k3",
"p", "pp"

);		
		
		my $vitaminsprefixregexp = "vitamine|vitamines";
		
		my $vitaminssuffixregexp = "";
		foreach my $suffix (@vitaminssuffixes) {
			$vitaminssuffixregexp .= '|' . $suffix;
			# vitamines [E, thiamine (B1), riboflavine (B2), B6, acide folique)].
			# -> also put (B1)
			$vitaminssuffixregexp .= '|\(' . $suffix . '\)';
			
			my $unaccented_suffix = unac_string_perl($suffix);
			if ($unaccented_suffix ne $suffix) {
				$vitaminssuffixregexp .= '|' . $unaccented_suffix;
			}
			if ($suffix =~ /[a-z]\d/) {
				
				
				$suffix =~ s/([a-z])(\d)/$1 $2/;
				$vitaminssuffixregexp .= '|' . $suffix;
				$suffix =~ s/ /-/;
				$vitaminssuffixregexp .= '|' . $suffix;
				
			}
			
		}
		$vitaminssuffixregexp =~ s/^\|//;		
		
		print STDERR "vitamins regexp: s/($vitaminsprefixregexp)(:|\(|\[| )?(($vitaminssuffixregexp)(\/| \/ | - |,|, | et ))+/\n";
	
		$text =~ s/($vitaminsprefixregexp)(:|\(|\[| )*((($vitaminssuffixregexp)( |\/| \/ | - |,|, | et ))+($vitaminssuffixregexp))\b/normalize_fr_vitamins_enumeration($3)/ieg;

	}
	
	my @ingredients = split($separators, $text);
	
	
	my @ingredients_ids = ();
	foreach my $ingredient (@ingredients) {
			
		my $ingredientid = get_fileid($ingredient);
		if ((defined $ingredientid) and ($ingredientid ne '')) {
			push @ingredients_ids, $ingredientid;
			# print STDERR "ingredient 3: $ingredient \n";
		}
	}
	
	$product_ref->{ingredients_debug} = clone(\@ingredients);
	$product_ref->{ingredients_ids_debug} = clone(\@ingredients_ids);
	
	my $with_sweeteners;
	
	my %all_seen = (); # used to not tag "huile végétale" if we have seen "huile de palme" already
	
	
	# Additives using new global taxonomy
	
	# delete old additive fields
	
	foreach my $tagtype ('additives', 'additives_prev', 'additives_next', 'old_additives', 'new_additives') {
	
		delete $product_ref->{$tagtype};
		delete $product_ref->{$tagtype . "_prev"};
		delete $product_ref->{$tagtype ."_prev_n"};
		delete $product_ref->{$tagtype . "_tags"};
	}
	
	delete $product_ref->{new_additives_debug};
	
	foreach my $tagtype ('additives', 'additives_prev', 'additives_next') {
	
		next if (not exists $loaded_taxonomies{$tagtype});
		
		$product_ref->{$tagtype . '_tags'} = [];		
		
		my $tagtype_suffix = $tagtype;
		$tagtype_suffix =~ s/[^_]+//;
		
		my $vitamins_tagtype = "vitamins" . $tagtype_suffix;
		my $minerals_tagtype = "minerals" . $tagtype_suffix;
		my $amino_acids_tagtype = "amino_acids" . $tagtype_suffix;
		my $nucleotides_tagtype = "nucleotides" . $tagtype_suffix;
		my $other_nutritional_substances_tagtype = "other_nutritional_substances" . $tagtype_suffix;
		$product_ref->{$vitamins_tagtype . '_tags'} = [];
		$product_ref->{$minerals_tagtype . '_tags'} = [];
		$product_ref->{$amino_acids_tagtype . '_tags'} = [];
		$product_ref->{$nucleotides_tagtype . '_tags'} = [];
		$product_ref->{$vitamins_tagtype . '_tags'} = [];
		
		my $class = $tagtype;		
		
			my %seen = ();
			my %seen_tags = ();
			
			# Keep track of mentions of the additive class (e.g. "coloring: X, Y, Z") so that we can correctly identify additives after
			my $current_additive_class = "ingredient";

			foreach my $ingredient_id (@ingredients_ids) {
			
				my $ingredient_id_copy = $ingredient_id; # can be modified later: soy-lecithin -> lecithin, but we don't change values of @ingredients_ids
			
				my $match = 0;
				while (not $match) {
				
					# additive class?
					my $canon_ingredient_additive_class = canonicalize_taxonomy_tag($product_ref->{lc}, "additives_classes", $ingredient_id_copy);
					
					if (exists_taxonomy_tag("additives_classes", $canon_ingredient_additive_class )) {
						$current_additive_class = $canon_ingredient_additive_class;
						# print STDERR "current_additive_class : $canon_ingredient_additive_class\n";
					}
				
					# additive?
					my $canon_ingredient = canonicalize_taxonomy_tag($product_ref->{lc}, $tagtype, $ingredient_id_copy);
					# in Hong Kong, the E- can be ommited in E-numbers
					my $canon_e_ingredient = canonicalize_taxonomy_tag($product_ref->{lc}, $tagtype, "e" . $ingredient_id_copy);
					my $canon_ingredient_vitamins = canonicalize_taxonomy_tag($product_ref->{lc}, "vitamins", $ingredient_id_copy);
					my $canon_ingredient_minerals = canonicalize_taxonomy_tag($product_ref->{lc}, "minerals", $ingredient_id_copy);
					my $canon_ingredient_amino_acids = canonicalize_taxonomy_tag($product_ref->{lc}, "amino_acids", $ingredient_id_copy);
					my $canon_ingredient_nucleotides = canonicalize_taxonomy_tag($product_ref->{lc}, "nucleotides", $ingredient_id_copy);
					my $canon_ingredient_other_nutritional_substances = canonicalize_taxonomy_tag($product_ref->{lc}, "other_nutritional_substances", $ingredient_id_copy);
					($ingredient_id_copy =~ /carniti/i) and print STDERR "other: $canon_ingredient_other_nutritional_substances\n";
					
					$product_ref->{$tagtype} .= " [ $ingredient_id_copy -> $canon_ingredient ";
					
					if (defined $seen{$canon_ingredient}) {
						$product_ref->{$tagtype} .= " -- already seen ";	
						$match = 1;
					}
					
					# For additives, first check if the current class is vitamins or minerals and if the ingredient
					# exists in the vitamins and minerals taxonomy
					
					elsif ((($current_additive_class eq "en:vitamins") or ($current_additive_class eq "en:minerals")
						or ($current_additive_class eq "en:amino-acids") or ($current_additive_class eq "en:nucleotides")
						or ($current_additive_class eq "en:other-nutritional-substances"))
					
					and (exists_taxonomy_tag("vitamins", $canon_ingredient_vitamins))) {
						$match = 1;
						$seen{$canon_ingredient} = 1;
						$product_ref->{$tagtype} .= " -> exists as a vitamin $canon_ingredient_vitamins and current class is $current_additive_class ";
						if (not exists $seen_tags{$vitamins_tagtype . '_tags' . $canon_ingredient_vitamins}) {
							push @{$product_ref->{ $vitamins_tagtype . '_tags'}}, $canon_ingredient_vitamins;
							$seen_tags{$vitamins_tagtype . '_tags' . $canon_ingredient_vitamins} = 1;
						}
					}
					
					elsif (($current_additive_class eq "en:minerals") and (exists_taxonomy_tag("minerals", $canon_ingredient_minerals))
						and not ($just_synonyms{"minerals"}{$canon_ingredient_minerals})) {
						$match = 1;
						$seen{$canon_ingredient} = 1;
						$product_ref->{$tagtype} .= " -> exists as a mineral $canon_ingredient_minerals and current class is $current_additive_class ";
						if (not exists $seen_tags{$minerals_tagtype . '_tags' . $canon_ingredient_minerals}) {
							push @{$product_ref->{ $minerals_tagtype . '_tags'}}, $canon_ingredient_minerals;
							$seen_tags{$minerals_tagtype . '_tags' . $canon_ingredient_minerals} = 1;
						}
					}					
					
					elsif ((exists_taxonomy_tag($tagtype, $canon_ingredient))
						# do not match synonyms
						and ($canon_ingredient !~ /^en:(fd|no|colour)/)
						) {
						
						$seen{$canon_ingredient} = 1;
						$product_ref->{$tagtype} .= " -> exists ";
						
						if ((defined $properties{$tagtype}{$canon_ingredient})
							and (defined $properties{$tagtype}{$canon_ingredient}{"mandatory_additive_class:en"})) {
							
							my $mandatory_additive_class = $properties{$tagtype}{$canon_ingredient}{"mandatory_additive_class:en"};
							# make the comma separated list a regexp
							$product_ref->{$tagtype} .= " -- mandatory_additive_class: $mandatory_additive_class (current: $current_additive_class) ";
							$mandatory_additive_class =~ s/,/\|/g;
							$mandatory_additive_class =~ s/\s//g;
							if ($current_additive_class =~ /^$mandatory_additive_class$/) {
								if (not exists $seen_tags{$tagtype . '_tags' . $canon_ingredient}) {
									push @{$product_ref->{ $tagtype . '_tags'}}, $canon_ingredient;
									$seen_tags{$tagtype . '_tags' . $canon_ingredient} = 1;
								}
								# success!
								$match = 1;		
								$product_ref->{$tagtype} .= " -- ok ";								
							}
						}
						else {
							if (not exists $seen_tags{$tagtype . '_tags' . $canon_ingredient}) {
								push @{$product_ref->{ $tagtype . '_tags'}}, $canon_ingredient;
								 $seen_tags{$tagtype . '_tags' . $canon_ingredient} = 1;
							}
							# success!
							$match = 1;
							$product_ref->{$tagtype} .= " -- ok ";	
						}
					}
					
					# continue to try to match a known additive, mineral or vitamin
					if (not $match) {
					
						
						# check if it is mineral or vitamin, even if we haven't seen "minerals" or "vitamins" before
						if ((exists_taxonomy_tag("vitamins", $canon_ingredient_vitamins))) {
							$match = 1;
							$seen{$canon_ingredient} = 1;
							$product_ref->{$tagtype} .= " -> exists as a vitamin $canon_ingredient_vitamins ";
							if (not exists $seen_tags{$vitamins_tagtype . '_tags' . $canon_ingredient_vitamins}) {
								push @{$product_ref->{ $vitamins_tagtype . '_tags'}}, $canon_ingredient_vitamins;
								$seen_tags{$vitamins_tagtype . '_tags' . $canon_ingredient_vitamins} = 1;
							}
							# set current class to vitamins
							$current_additive_class = "en:vitamins";
						}
						
						elsif ((exists_taxonomy_tag("minerals", $canon_ingredient_minerals))
							and not ($just_synonyms{"minerals"}{$canon_ingredient_minerals})) {
							$match = 1;
							$seen{$canon_ingredient} = 1;
							$product_ref->{$tagtype} .= " -> exists as a mineral $canon_ingredient_minerals ";
							if (not exists $seen_tags{$minerals_tagtype . '_tags' . $canon_ingredient_minerals}) {
								push @{$product_ref->{ $minerals_tagtype . '_tags'}}, $canon_ingredient_minerals;
								$seen_tags{$minerals_tagtype . '_tags' . $canon_ingredient_minerals} = 1;
							}
							$current_additive_class = "en:minerals";
						}	
						
						if ((exists_taxonomy_tag("amino_acids", $canon_ingredient_amino_acids))) {
							$match = 1;
							$seen{$canon_ingredient} = 1;
							$product_ref->{$tagtype} .= " -> exists as a amino_acid $canon_ingredient_amino_acids ";
							if (not exists $seen_tags{$amino_acids_tagtype . '_tags' . $canon_ingredient_amino_acids}) {
								push @{$product_ref->{ $amino_acids_tagtype . '_tags'}}, $canon_ingredient_amino_acids;
								$seen_tags{$amino_acids_tagtype . '_tags' . $canon_ingredient_amino_acids} = 1;
							}
							$current_additive_class = "en:amino-acids";
						}
						
						elsif ((exists_taxonomy_tag("nucleotides", $canon_ingredient_nucleotides))) {
							$match = 1;
							$seen{$canon_ingredient} = 1;
							$product_ref->{$tagtype} .= " -> exists as a nucleotide $canon_ingredient_nucleotides ";
							if (not exists $seen_tags{$nucleotides_tagtype . '_tags' . $canon_ingredient_nucleotides}) {
								push @{$product_ref->{ $nucleotides_tagtype . '_tags'}}, $canon_ingredient_nucleotides;
								$seen_tags{$nucleotides_tagtype . '_tags' . $canon_ingredient_nucleotides} = 1;
							}
							$current_additive_class = "en:nucleotides";
						}	

						elsif ((exists_taxonomy_tag("other_nutritional_substances", $canon_ingredient_other_nutritional_substances))) {
							$match = 1;
							$seen{$canon_ingredient} = 1;
							$product_ref->{$tagtype} .= " -> exists as a other_nutritional_substance $canon_ingredient_other_nutritional_substances ";
							if (not exists $seen_tags{$other_nutritional_substances_tagtype . '_tags' . $canon_ingredient_other_nutritional_substances}) {
								push @{$product_ref->{ $other_nutritional_substances_tagtype . '_tags'}}, $canon_ingredient_other_nutritional_substances;
								$seen_tags{$other_nutritional_substances_tagtype . '_tags' . $canon_ingredient_other_nutritional_substances} = 1;
							}
							$current_additive_class = "en:other-nutritional-substances";
						}			

						# in Hong Kong, the E- can be ommited in E-numbers
						
						elsif (($canon_ingredient =~ /^en:(\d+)( |-)?([a-z])??(i|ii|iii|iv|v|vi|vii|viii|ix|x|xi|xii|xii|xiv|xv)?$/i)
							and (exists_taxonomy_tag($tagtype, $canon_e_ingredient))) {
					
							$seen{$canon_e_ingredient} = 1;
							$product_ref->{$tagtype} .= " -> e-ingredient exists  ";
						
							if (not exists $seen_tags{$tagtype . '_tags' . $canon_e_ingredient}) {
								push @{$product_ref->{ $tagtype . '_tags'}}, $canon_e_ingredient;
								 $seen_tags{$tagtype . '_tags' . $canon_e_ingredient} = 1;
							}
							# success!
							$match = 1;
							$product_ref->{$tagtype} .= " -- ok ";	
						}
						
						# try to shorten the ingredient to make it less specific, to see if it matches then
						
						elsif (($lc eq 'en') and ($ingredient_id_copy =~ /^([^-]+)-/)) {
							# soy lecithin -> lecithin
							$ingredient_id_copy = $';
						}
						elsif (($lc eq 'fr') and ($ingredient_id_copy =~ /-([^-]+)$/)) {
							# lécithine de soja -> lécithine de -> lécithine
							$ingredient_id_copy = $`;
						}
						
						else {
							# give up
							$match = 1;
						}
					}
					$product_ref->{$tagtype} .= " ] ";
				}
			}
		
		
		# Also generate a list of additives with the parents (e.g. E500ii adds E500)
		$product_ref->{ $tagtype . '_original_tags'} = $product_ref->{ $tagtype . '_tags'};
		$product_ref->{ $tagtype . '_tags'} = [ sort(gen_tags_hierarchy_taxonomy("en", $tagtype, join(', ', @{$product_ref->{ $tagtype . '_original_tags'}})))];
		
		
		# No ingredients?
		if ($product_ref->{ingredients_text} eq '') {
			delete $product_ref->{$tagtype . '_n'};
		}
		else {
			# count the original list of additives, don't count E500ii as both E500 and E500ii
			if (defined $product_ref->{$tagtype . '_original_tags'}) {
				$product_ref->{$tagtype. '_n'} = scalar @{$product_ref->{ $tagtype . '_original_tags'}};
			}
			else {
				delete $product_ref->{$tagtype . '_n'};
			}
		}	
	}
	
	
	
	foreach my $class (sort keys %ingredients_classes) {
		
		my $tagtype = $class;
		
		if ($tagtype eq 'additives') {
			$tagtype = 'additives_old';
		}
		
		$product_ref->{$tagtype . '_tags'} = [];		
				
		# skip palm oil classes if there is a palm oil free label
		if (($class =~ /palm/) and ($product_ref->{labels_tags} ~~ 'en:palm-oil-free')) {
			
		}
		else {
		
			my %seen = ();

			foreach my $ingredient_id (@ingredients_ids) {
			
				#$product_ref->{$tagtype . "_debug_ingredients_ids" } .=  " ; " . $ingredient_id . " ";
			
				if ((defined $ingredients_classes{$class}{$ingredient_id}) and (not defined $seen{$ingredients_classes{$class}{$ingredient_id}{id}})) {
				
					next if (($ingredients_classes{$class}{$ingredient_id}{id} eq 'huile-vegetale') and (defined $all_seen{"huile-de-palme"}));
					
					#$product_ref->{$tagtype . "_debug_ingredients_ids" } .= " -> exact match $ingredients_classes{$class}{$ingredient_id}{id} ";
				
					push @{$product_ref->{$tagtype . '_tags'}}, $ingredients_classes{$class}{$ingredient_id}{id};
					$seen{$ingredients_classes{$class}{$ingredient_id}{id}} = 1;
					$all_seen{$ingredients_classes{$class}{$ingredient_id}{id}} = 1;
					
				}
				else {
				
					#$product_ref->{$tagtype . "_debug_ingredients_ids" } .= " -> no exact match ";
				
					foreach my $id (@{$ingredients_classes_sorted{$class}}) {
						if (($ingredient_id =~ /^$id\b/) and (not defined $seen{$ingredients_classes{$class}{$id}{id}})) {
						
							next if (($ingredients_classes{$class}{$id}{id} eq 'huile-vegetale') and (defined $all_seen{"huile-de-palme"}));
							
							#$product_ref->{$tagtype . "_debug_ingredients_ids" } .= " -> match $id - $ingredients_classes{$class}{$id}{id} ";
						
							push @{$product_ref->{$tagtype . '_tags'}}, $ingredients_classes{$class}{$id}{id};
							$seen{$ingredients_classes{$class}{$id}{id}} = 1;	
							$all_seen{$ingredients_classes{$class}{$id}{id}} = 1;				

							($product_ref->{code} eq '3245414658769') and print STDERR "extract_ingredient_classes 2 : id: $id - id/id: $ingredients_classes{$class}{$id}{id}\n";
							
						}
					}
				}						
			}
		}
				
		# No ingredients?
		if ($product_ref->{ingredients_text} eq '') {
			delete $product_ref->{$tagtype . '_n'};
		}
		else {
			$product_ref->{$tagtype . '_n'} = scalar @{$product_ref->{$tagtype . '_tags'}};
		}	
	}
	
	for (my $i = 0; $i < (scalar @{$product_ref->{additives_old_tags}}); $i++) {
		$product_ref->{additives_old_tags}[$i] = 'en:' . $product_ref->{additives_old_tags}[$i];
	}
	
	
	# keep the old additives for France until we can fix the new taxonomy matching to support all special cases
	# e.g. lecithine de soja
	#if ($product_ref->{lc} ne 'fr') {
	#	$product_ref->{additives_tags} = $product_ref->{new_additives_tags};
	#	$product_ref->{additives_tags_n} = $product_ref->{new_additives_tags_n};
	#}
	
	# compute minus and debug values
	
	my $field = 'additives';
	
	# check if we have a previous or a next version and compute differences
	
	$product_ref->{$field . "_debug_tags"} = [];


	
	# previous version
	
	if (exists $loaded_taxonomies{$field . "_prev"}) {
		
		# compute differences
		foreach my $tag (@{$product_ref->{$field . "_tags"}}) {
			if (not has_tag($product_ref,$field . "_prev",$tag)) {
				my $tagid = $tag;
				$tagid =~ s/:/-/;
				push @{$product_ref->{$field . "_debug_tags"}}, "$tagid-added";
			}
		}
		foreach my $tag (@{$product_ref->{$field . "_prev_tags"}}) {
			if (not has_tag($product_ref,$field,$tag)) {
				my $tagid = $tag;
				$tagid =~ s/:/-/;
				push @{$product_ref->{$field . "_debug_tags"}}, "$tagid-removed";
			}
		}			
	}
	else {
		delete $product_ref->{$field . "_prev_hierarchy" };
		delete $product_ref->{$field . "_prev_tags" };
	}	
	
	# next version
	
	if (exists $loaded_taxonomies{$field . "_next"}) {
		
		# compute differences
		foreach my $tag (@{$product_ref->{$field . "_tags"}}) {
			if (not has_tag($product_ref,$field . "_next",$tag)) {
				my $tagid = $tag;
				$tagid =~ s/:/-/;
				push @{$product_ref->{$field . "_debug_tags"}}, "$tagid-will-remove";
			}
		}
		foreach my $tag (@{$product_ref->{$field . "_next_tags"}}) {
			if (not has_tag($product_ref,$field,$tag)) {
				my $tagid = $tag;
				$tagid =~ s/:/-/;
				push @{$product_ref->{$field . "_debug_tags"}}, "$tagid-will-add";
			}
		}			
	}
	else {
		delete $product_ref->{$field . "_next_hierarchy" };
		delete $product_ref->{$field . "_next_tags" };
	}	

	

	
	if ((defined $product_ref->{ingredients_that_may_be_from_palm_oil_n}) or (defined $product_ref->{ingredients_from_palm_oil_n})) {
		$product_ref->{ingredients_from_or_that_may_be_from_palm_oil_n} = $product_ref->{ingredients_that_may_be_from_palm_oil_n} + $product_ref->{ingredients_from_palm_oil_n};
	}
	
	
	delete $product_ref->{with_sweeteners};
	foreach my $additive (@{$product_ref->{'additives_tags'}}) {
		my $e = $additive;
		$e =~ s/\D//g;
		if (($e >= 950) and ($e <= 968)) {
			$product_ref->{with_sweeteners} = 1;
			last;
		}
	}
}



sub replace_allergen($$$) {
	my $language = shift;
	my $product_ref = shift;
	my $allergen = shift;
	
	# to build the product allergens list, just use the ingredients in the main language
	if ($language eq $product_ref->{lc}) {
		$product_ref->{allergens} .= $allergen . ', ';
	}
	
	return '<span class="allergen">' . $allergen . '</span>';
}


sub replace_caps($$$) {
	my $language = shift;
	my $product_ref = shift;
	my $allergen = shift;
	
	my $tagid = canonicalize_taxonomy_tag($language,"allergens", $allergen);
	if (exists_taxonomy_tag("allergens", $tagid)) {
		#$allergen = display_taxonomy_tag($product_ref->{lang},"allergens", $tagid);
		# to build the product allergens list, just use the ingredients in the main language
		if ($language eq $product_ref->{lc}) {
			$product_ref->{allergens} .= $allergen . ', ';
		}
		return '<span class="allergen">' . $allergen . '</span>';
	}
	else {
		return $allergen;
	}		
}


sub detect_allergens_from_text($) {

	my $product_ref = shift;
	my $path = product_path($product_ref->{code});
	
	
	$product_ref->{allergens} = "";

	
	if (defined $product_ref->{languages_codes}) {
	
		foreach my $language (keys %{$product_ref->{languages_codes}}) {
		
			my $text = $product_ref->{"ingredients_text_" . $language };
	
			$text =~ s/\b_([^,;_\(\)\[\]]+?)_\b/replace_allergen($language,$product_ref,$1)/iesg;
	
			if ($text =~ /[a-z]/) {
				$text =~ s/\b([A-ZÌÒÁÉÍÓÚÝÂÊÎÔÛÃÑÕÄËÏÖŸÇŒß][A-ZÌÒÁÉÍÓÚÝÂÊÎÔÛÃÑÕÄËÏÖŸÇŒß]([A-ZÌÒÁÉÍÓÚÝÂÊÎÔÛÃÑÕÄËÏÖŸÇŒß]+))\b/replace_caps($language,$product_ref,$1)/esg;
			}
			
			$product_ref->{"ingredients_text_with_allergens_" . $language} = $text;
			
			if ($language eq $product_ref->{lc}) {
				$product_ref->{"ingredients_text_with_allergens"} = $text;
			}
		
		}
	}
	
	$product_ref->{allergens} =~ s/, $//;

	my $field = 'allergens';
	$product_ref->{$field . "_hierarchy" } = [ gen_tags_hierarchy_taxonomy($product_ref->{lang}, $field, $product_ref->{$field}) ];
	$product_ref->{$field . "_tags" } = [];
	foreach my $tag (@{$product_ref->{$field . "_hierarchy" }}) {
		push @{$product_ref->{$field . "_tags" }}, get_taxonomyid($tag);
	}	
	
}






1;
