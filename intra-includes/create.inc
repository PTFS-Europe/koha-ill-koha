<!-- Error Handling -->
[% IF whole.error %]
    <!-- Dispatch on Status -->
    <p>We encountered an error:</p>
    <ol>
        <li>[% whole.status %]</li>
        <li>[% whole.message %]</li>
    </ol>
[% END %]

[% IF whole.stage == "search_form" %]
    <h2>Search other Koha systems</h2>
    <form class="validated" method="post" action="/cgi-bin/koha/ill/ill-requests.pl">
        <input type="hidden" name="stage" value="[% whole.stage %]"/>
        <input type="hidden" name="method" value="[% whole.method %]"/>
        <input type="hidden" name="op" value="[% whole.method %]"/>
        <input name="backend" id="method" value="[% whole.value.other.backend %]" type="hidden"/>
        <fieldset class="rows">
            <ol>
                <li>
                    <label class="required" for="search">Search string: </label>
                    <input class="required" required="required" type="text" name="search" value="" />
                    <span class="required">Required</span>
                </li>
                <li>
                    <label class="required" for="cardnumber">Card number: </label>
                    <input class="required" required="required" type="text" name="cardnumber" value="" />
                    <span class="required">Required</span>
                </li>
                <li>
                    <label class="required" for="branchcode">Pickup branch: </label>
                    <select class="required" required="required" id="branchcode" name="branchcode">
                        [% FOREACH branch IN branches %]
                            <option value="[% branch.branchcode %]">
                        [% branch.branchname %]
                            </option>
                        [% END %]
                    </select>
                    <span class="required">Required</span>
                </li>
            </ol>
        </fieldset>
        <fieldset class="action">
            <input type="submit" value="Search"/>
            <a class="cancel" href="/cgi-bin/koha/ill/ill-requests.pl">Cancel</a>
        </fieldset>
    </form>

[% ELSIF whole.stage == "search_results" %]
  [% IF whole.value %]
    [% FOREACH target IN whole.value %]
      [% name = target.key %]
      [% IF target.value.0.defined %]
        <h2>Select a [% name %] request</h2>
        <table>
          <thead>
            <tr>
              <th id="id">ID</th>
              <th id="title">Title</th>
              <th id="author">Author</th>
              <th id="select">Select?</th>
            </tr>
          </thead>
          <tbody>
            [% FOREACH candidate IN target.value %]
            <tr>
              <td>[% candidate.bib_id %]</td>
              <td>[% candidate.title %]</td>
              <td>[% candidate.author %]</td>
              [% target = "/cgi-bin/koha/ill/ill-requests.pl"
              _ "?method=" _ whole.method
              _ "&amp;target=" _ name
              _ "&amp;stage=" _ whole.stage
              _ "&amp;backend=" _ whole.backend
              _ "&amp;borrowernumber=" _ whole.borrowernumber
              _ "&amp;branchcode=" _ whole.branchcode
              _ "&amp;author=" _ candidate.author
              _ "&amp;title=" _ candidate.title
              _ "&amp;bib_id=" _ candidate.bib_id %]
              <td>
                <a class="btn btn-sm btn-default" href="[% target %]">Request this item</a>
              </td>
            </tr>
            [% END %]
          </tbody>
        </table>
      [% ELSE %]
        <h2>Search failed for [% name %]</h2>
        <p>[% target.value %]</p>
      [% END %]
    [% END %]
  [% ELSE %]
    <p>We have no results</p>
  [% END %]

[% ELSE %]
    <p>We encountered an unexpected situation</p>

[% END %]
