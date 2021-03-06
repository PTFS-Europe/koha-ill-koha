<!-- Error Handling -->
[% IF whole.error %]
    <!-- Dispatch on Status -->
    <p>We encountered an error:</p>
    <ol>
        <li>[% whole.status %]</li>
        <li>[% whole.message %]</li>
    </ol>
[% END %]

[% IF whole.stage == "immigrate" %]
  [% IF whole.step == "search_form" %]
    <h2>Search Koha Partners</h2>
    <form class="validated" method="post" action="/cgi-bin/koha/ill/ill-requests.pl">
        <input type="hidden" name="stage" value="[% whole.stage %]"/>
        <input type="hidden" name="method" value="[% whole.method %]"/>
        <input type="hidden" name="op" value="[% whole.method %]"/>
        <input type="hidden" name="backend" value="[% whole.value.other.backend %]" id="method"/>
        <fieldset class="rows">
        <legend>Search Koha Partners</legend>
            <ol>
                <li>
                    <label for="search">Keyword: </label>
                    <input type="text" name="srchany" value="" />
                </li>
                <li>
                    <label for="search">ISBN: </label>
                    <input type="text" name="isbn" value="" />
                </li>
                <li>
                    <label for="search">ISSN: </label>
                    <input type="text" name="issn" value="" />
                </li>
                <li>
                    <label for="search">Title: </label>
                    <input type="text" name="title" value="" />
                </li>
                <li>
                    <label for="search">Author: </label>
                    <input type="text" name="author" value="" />
                </li>
            </ol>
        </fieldset>
        <fieldset class="action">
            <input type="submit" value="Search"/>
            <a class="cancel" href="/cgi-bin/koha/ill/ill-requests.pl">Cancel</a>
        </fieldset>
    </form>

  [% ELSIF whole.step == "search_results" %]
    [% IF whole.value %]
      [% IF ( whole.value.errors ) %]
              <div class="dialog alert">
                  <ul>
                  [% FOREACH error IN whole.value.errors %]
                      [% IF ( error.error == '10000' ) %]<li>Connection failed to [% error.server %]</li>
                      [% ELSIF ( error.error == '10007' ) %]<li>Connection timeout to [% error.server %]</li>
                      [% ELSIF ( error.error == 'xslt_err' ) %]<li>[% error.server %]: Warning: XSLT error on search result [% error.seq %]</li>
                      [% ELSE %]<li>[% error.server %] record [% error.seq %]: [% error.error %]</li>
                      [% END %]
                  [% END %]
                  </ul>
              </div>
      [% END %]
  
      <h2>Select an item to request</h2>
      [% IF whole.value.results %]
        <table>
          <thead>
            <tr>
              <th id="partner">Partner</th>
              <th id="title">Title</th>
              <th id="author">Author</th>
              <th id="isbn">ISBN</th>
              <th id="select">Select?</th>
            </tr>
          </thead>
          <tbody>
            [% FOREACH result IN whole.value.results %]
            <tr>
              <td>[% result.server %]</td>
              <td>[% result.title %]</td>
              <td>[% result.author %]</td>
              <td>[% result.isbn %]</td>
              [% target = "/cgi-bin/koha/ill/ill-requests.pl"
              _ "?method=" _ whole.method
              _ "&amp;target=" _ result.server
              _ "&amp;stage=" _ whole.stage
              _ "&amp;step=" _ whole.step
              _ "&amp;backend=" _ whole.backend
              _ "&amp;illrequest_id=" _ whole.illrequest_id
              _ "&amp;author=" _ result.author
              _ "&amp;title=" _ result.title
              _ "&amp;breedingid=" _ result.breedingid %]
              <td>
                <a class="btn btn-sm btn-default" href="[% target %]">Request this item</a>
              </td>
            </tr>
            [% END %]
          </tbody>
        </table>
      [% ELSE %]
        <p>We have no results</p>
      [% END %]
    [% END %]
  [% END %]

[% ELSE %]
    <p>We encountered an unexpected situation</p>
[% END %]
