function result = ai_install_info()
paths = strsplit(userpath,pathsep);
paths = paths(~cellfun(@isempty,paths));
result = jsonencode(struct('user_paths',{paths},'existing_startup',which('startup'), ...
    'matlabroot',matlabroot,'desktop',usejava('desktop')));
end
