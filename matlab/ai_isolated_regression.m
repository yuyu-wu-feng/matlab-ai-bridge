function ai_isolated_regression()
% Run only in a new MATLAB desktop started in tests/isolated_matlab.
root=fileparts(fileparts(mfilename('fullpath')));
report=struct;
try, report.editor=jsondecode(ai_workflow_test(false));
catch e, report.editor=struct('ok',false,'error',e.message); end
report.ok=report.editor.ok;
file=fullfile(root,'output','isolated-regression.json');
fid=fopen(file,'w','n','UTF-8'); cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(report),'UTF-8'),'uint8');
disp(jsonencode(report));
end
