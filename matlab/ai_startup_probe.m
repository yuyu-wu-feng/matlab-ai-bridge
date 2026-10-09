% Run only in a disposable desktop. Verify startup without opening the UI here.
probeRoot = fileparts(fileparts(mfilename('fullpath')));
probeDeadline = tic;
probeFigures = findall(groot,'Type','figure','Name','MATLAB AI 助手');
while isempty(probeFigures) && toc(probeDeadline) < 30
    pause(0.2);
    drawnow;
    probeFigures = findall(groot,'Type','figure','Name','MATLAB AI 助手');
end
probeReport = struct('ok',numel(probeFigures)==1, ...
    'automatic_window_count',numel(probeFigures),'desktop',usejava('desktop'), ...
    'startup_file',which('startup'),'matlab_pid',feature('getpid'));
if ~isempty(probeFigures)
    probeReport.visible = strcmp(probeFigures(1).Visible,'on');
    probeReport.ok = probeReport.ok && probeReport.visible;
end
probeFile = fopen(fullfile(probeRoot,'output','startup-test.json'),'w','n','UTF-8');
fprintf(probeFile,'%s',jsonencode(probeReport,PrettyPrint=true));
fclose(probeFile);
disp(jsonencode(probeReport));
