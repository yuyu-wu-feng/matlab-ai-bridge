function html = ai_diff_html(before, after)
% Render a line-based diff using a bounded LCS; HTML contains no executable code.
a = splitlines(string(strrep(before, sprintf('\r\n'), newline)));
b = splitlines(string(strrep(after, sprintf('\r\n'), newline)));
n = numel(a); m = numel(b);
rows = strings(0,1);
if n*m > 1500000
    % Large documents: still show every removed/added line without quadratic work.
    for i=1:n, rows(end+1) = row('del','−',a(i)); end
    for j=1:m, rows(end+1) = row('add','+',b(j)); end
else
    lengths = zeros(n+1,m+1,'uint32');
    for i=n:-1:1
        for j=m:-1:1
            if a(i)==b(j), lengths(i,j)=1+lengths(i+1,j+1);
            else, lengths(i,j)=max(lengths(i+1,j),lengths(i,j+1)); end
        end
    end
    i=1; j=1;
    while i<=n || j<=m
        if i<=n && j<=m && a(i)==b(j)
            rows(end+1)=row('same',' ',a(i)); i=i+1; j=j+1;
        elseif j<=m && (i>n || lengths(i,j+1)>lengths(i+1,j))
            rows(end+1)=row('add','+',b(j)); j=j+1;
        else
            rows(end+1)=row('del','−',a(i)); i=i+1;
        end
    end
end
html = char("<!doctype html><html><head><meta charset='utf-8'><style>" + ...
    "body{margin:0;padding:12px;background:#fafbfe;color:#263449}" + ...
    "pre{font:13px/1.65 Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere}" + ...
    ".add{background:#ddf5e7;color:#155c34}.del{background:#fce2e2;color:#912727}" + ...
    ".same{color:#526173}</style></head><body><pre>" + join(rows,"") + "</pre></body></html>");
end

function result = row(css, marker, text)
text = replace(text, '&','&amp;'); text = replace(text,'<','&lt;');
text = replace(text,'>','&gt;'); text = replace(text,'"','&quot;');
result = "<div class='" + css + "'>" + marker + " " + text + "</div>";
end
