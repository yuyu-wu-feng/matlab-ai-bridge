function blocks = ai_change_blocks(before,after)
% Exact line chunks, retaining original newline bytes for reversible selection.
a = regexp(char(before),'[^\n]*\n|[^\n]+$','match');
b = regexp(char(after),'[^\n]*\n|[^\n]+$','match');
n = numel(a); m = numel(b);
blocks = struct('start',{},'stop',{},'replacement',{},'line',{},'oldCount',{},'newCount',{});
if strcmp(before,after), return; end
if n*m>1500000
    blocks = struct('start',1,'stop',numel(before)+1,'replacement',char(after), ...
        'line',1,'oldCount',n,'newCount',m);
    return;
end
lengths = zeros(n+1,m+1,'uint32');
for i=n:-1:1
    for j=m:-1:1
        if strcmp(a{i},b{j}), lengths(i,j)=1+lengths(i+1,j+1);
        else, lengths(i,j)=max(lengths(i+1,j),lengths(i,j+1)); end
    end
end
i=1; j=1; offset=1;
while i<=n || j<=m
    if i<=n && j<=m && strcmp(a{i},b{j})
        offset=offset+numel(a{i}); i=i+1; j=j+1;
        continue;
    end
    block = struct('start',offset,'stop',offset,'replacement','','line',i,'oldCount',0,'newCount',0);
    while i<=n || j<=m
        if i<=n && j<=m && strcmp(a{i},b{j}), break; end
        if j<=m && (i>n || lengths(i,j+1)>lengths(i+1,j))
            block.replacement=[block.replacement b{j}]; j=j+1; block.newCount=block.newCount+1;
        else
            offset=offset+numel(a{i}); i=i+1; block.oldCount=block.oldCount+1;
        end
    end
    block.stop=offset;
    blocks(end+1)=block;
end
end
