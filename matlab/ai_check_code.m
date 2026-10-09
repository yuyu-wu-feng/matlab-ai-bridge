function report = ai_check_code(code)
% Static Code Analyzer inspection only; never evaluate generated MATLAB code.
root = fileparts(fileparts(mfilename('fullpath')));
folder = fullfile(root,'output','checks',char(java.util.UUID.randomUUID));
mkdir(folder);
cleanup = onCleanup(@() rmdir(folder,'s'));
filename = 'generated_preview';
token = regexp(code,'(?m)^\s*function\s+(?:\[[^\]]*\]\s*=\s*|\w+\s*=\s*)?(\w+)\s*\(','tokens','once');
if ~isempty(token), filename = token{1}; end
path = fullfile(folder,[filename '.m']);
fid = fopen(path,'w','n','UTF-8');
if fid<0, error('MatlabAI:CheckFile','无法创建临时代码检查文件。'); end
closeFile = onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(code,'UTF-8'),'uint8');
clear closeFile;
messages = checkcode(path,'-id');
lines = {'MATLAB 静态代码检查（未运行代码；不能保证业务逻辑正确）'};
if isempty(messages)
    lines{end+1} = '未发现 Code Analyzer 提示。';
else
    lines{end+1} = sprintf('发现 %d 项提示：',numel(messages));
    for k=1:numel(messages)
        lines{end+1} = sprintf('第 %d 行 [%s] %s',messages(k).line,messages(k).id,messages(k).message);
    end
end
report = struct('count',numel(messages),'messages',messages,'lines',{lines});
end
