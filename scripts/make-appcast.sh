#!/bin/sh
# Writes appcast.xml, the feed Sparkle checks (see Info-Mac.plist), for one release.
# Usage: make-appcast.sh VERSION BUILD ZIP_URL SIGN_UPDATE_OUTPUT NOTES_FILE > appcast.xml
# SIGN_UPDATE_OUTPUT is sign_update's: sparkle:edSignature="…" length="…". NOTES_FILE holds the
# release notes as "- item" lines (the tag's message), shown in the update window.
set -eu
version=$1 build=$2 url=$3 signature=$4 notes=$5
items=$(sed -n 's/^- //p' "$notes" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|.*|<li>&</li>|')
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>telly for Mac</title>
    <item>
      <title>telly $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>$items</ul>]]></description>
      <enclosure url="$url" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
XML
