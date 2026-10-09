function first_start_test(projectRoot)
% Use copies in a fresh directory: never rename the user's real config.
folder=tempname; mkdir(folder); mkdir(fullfile(folder,'matlab'));
cleanup=onCleanup(@() cleanFolder(folder));
names={'matlab_ai.m','matlab_ai_setup.m','AISetupWizard.m','ai_backend_config.m'};
for i=1:numel(names)
    copyfile(fullfile(projectRoot,'matlab',names{i}),fullfile(folder,'matlab',names{i}));
end
addpath(fullfile(folder,'matlab'),'-begin');
app=matlab_ai; assert(isempty(app));
w=matlab_ai_setup; assert(isa(w,'AISetupWizard') && w.OpenAssistant && ~w.Saved);
assert(strcmp(w.Root,folder)); assert(~isfile(fullfile(folder,'config.local.json'))); delete(w);
fid=fopen(fullfile(folder,'config.local.json'),'w'); fprintf(fid,'{broken'); fclose(fid);
app=matlab_ai; assert(isempty(app)); w=matlab_ai_setup;
assert(~w.Saved); delete(w);
assert(strcmp(fileread(fullfile(folder,'config.local.json')),'{broken'));
c=struct('python_executable',fullfile(folder,'missing-python.exe'),'model','test');
fid=fopen(fullfile(folder,'config.local.json'),'w'); fprintf(fid,'%s',jsonencode(c)); fclose(fid);
app=matlab_ai; assert(isempty(app)); w=matlab_ai_setup;
assert(~w.Saved); delete(w);
result=jsonencode(struct('ok',true,'missing_config_opens_wizard',true, ...
    'corrupt_config_preserved',true,'missing_python_opens_wizard',true,'model_called',false));
disp(result);
fid=fopen(fullfile(projectRoot,'output','test-first-start.json'),'w'); fprintf(fid,'%s',result); fclose(fid);
end
function cleanFolder(folder)
directory=fullfile(folder,'matlab');
if ismember(directory,strsplit(path,pathsep)), rmpath(directory); end
if isfolder(folder), rmdir(folder,'s'); end
end
