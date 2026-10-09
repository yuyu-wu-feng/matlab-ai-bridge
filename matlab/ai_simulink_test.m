function result=ai_simulink_test(includeModel)
if nargin<1, includeModel=false; end
checks=struct; app=[];
model=['ai_sim_test_' strrep(char(java.util.UUID.randomUUID),'-','')];
new_system(model);
cleanup=onCleanup(@() close_system(model,0));
try
    load_system('simulink');
    add_block('simulink/Sources/Constant',[model '/Input'],'Value','3');
    add_block('simulink/Math Operations/Gain',[model '/Gain'],'Gain','2','Position',[150 60 200 100]);
    add_block('simulink/Sinks/Terminator',[model '/Output'],'Position',[350 60 370 80]);
    add_line(model,'Input/1','Gain/1'); add_line(model,'Gain/1','Output/1');
    add_block('simulink/Sinks/Terminator',[model '/Branch']); add_line(model,'Gain/1','Branch/1');
    baseline=ai_simulink_snapshot(model);
    assert(numel(baseline.blocks)==4 && numel(baseline.connections)==3); checks.read_model_and_connections=true;
    line=get_param([model '/Output'],'LineHandles'); set_param(line.Inport,'Selected','on');
    lineSelection=AISimulinkTransaction(model,'sim_explain','selection');
    assert(contains(lineSelection.Context,'selected_lines') && ismember('Output',lineSelection.Selected));
    checks.selected_signal_line_endpoints=true; set_param(line.Inport,'Selected','off');
    set_param([model '/Gain'],'Selected','on');
    t=AISimulinkTransaction(model,'sim_explain','selection');
    assert(ismember('Gain',t.Selected) && contains(t.Context,'Input')); checks.selected_block_neighbors=true;
    checks.explanation_read_only=expectError(@() t.propose('x'),'MatlabAI:SimReadOnly');
    ops={struct('op','set','path','Gain','parameter','Gain','value','4'), ...
        struct('op','add','path','Extra','kind','Gain','position',[240 60 290 100]), ...
        struct('op','set','path','Extra','parameter','Gain','value','5'), ...
        struct('op','disconnect','source','Gain','source_port',1,'target','Output','target_port',1), ...
        struct('op','connect','source','Gain','source_port',1,'target','Extra','target_port',1), ...
        struct('op','connect','source','Extra','source_port',1,'target','Output','target_port',1)};
    plan=jsonencode(struct('operations',{ops}));
    t=AISimulinkTransaction(model,'sim_edit','file'); t.propose(plan);
    assert(strcmp(jsonencode(ai_simulink_snapshot(model)),jsonencode(baseline))); checks.preview_no_mutation=true;
    t.apply; assert(strcmp(get_param([model '/Gain'],'Gain'),'4') && get_param([model '/Extra'],'Handle')>0);
    checks.add_connect_set_applied=true;
    t.restore; assert(strcmp(jsonencode(ai_simulink_snapshot(model)),jsonencode(baseline))); checks.model_restored=true;
    checks.branched_signal_preserved=true;
    t=AISimulinkTransaction(model,'sim_edit','file'); t.propose(plan); t.apply;
    set_param([model '/Gain'],'Gain','7');
    checks.restore_conflict_blocked=expectError(@() t.restore,'MatlabAI:Conflict');
    set_param([model '/Gain'],'Gain','4'); t.restore;
    t=AISimulinkTransaction(model,'sim_edit','file'); t.propose(plan);
    set_param([model '/Gain'],'Gain','8');
    checks.concurrent_change_blocked=expectError(@() t.apply,'MatlabAI:Conflict'); set_param([model '/Gain'],'Gain','2');
    t=AISimulinkTransaction(model,'sim_edit','file');
    bad=ops(1:2); bad{end+1}=struct('op','connect','source','Extra','source_port',9,'target','Output','target_port',1);
    t.propose(jsonencode(struct('operations',{bad})));
    checks.failed_apply_rolls_back=expectError(@() t.apply,'MatlabAI:SimPorts');
    assert(strcmp(jsonencode(ai_simulink_snapshot(model)),jsonencode(baseline)));
    bad={struct('op','set','path','Gain','parameter','DeleteFcn','value','evil')};
    checks.callbacks_rejected=expectError(@() t.propose(jsonencode(struct('operations',{bad}))),'MatlabAI:SimParameter');
    bad={struct('op','set','path','Gain','parameter','Gain','value','system(cmd)')};
    checks.executable_parameter_rejected=expectError(@() t.propose(jsonencode(struct('operations',{bad}))),'MatlabAI:SimValue');
    for value={'1;quit','quit'}
        bad={struct('op','set','path','Gain','parameter','Gain','value',value{1})};
        expectError(@() t.propose(jsonencode(struct('operations',{bad}))),'MatlabAI:SimValue');
    end
    checks.bare_commands_rejected=true;
    add_block('simulink/User-Defined Functions/MATLAB Function',[model '/Function']);
    set_param([model '/Gain'],'Selected','off'); set_param([model '/Function'],'Selected','on');
    t=AISimulinkTransaction(model,'sim_function','selection'); original=t.BaseText;
    replacement=sprintf('function y = fcn(u)\ny = u .* u;\nend');
    t.propose(replacement); chart=find(sfroot,'-isa','Stateflow.EMChart','Path',[model '/Function']);
    assert(strcmp(chart.Script,original)); t.apply; assert(strcmp(chart.Script,replacement)); t.restore;
    assert(strcmp(chart.Script,original)); checks.matlab_function_preview_apply_restore=true;
    t=AISimulinkTransaction(model,'sim_function','selection');
    checks.function_interface_change_blocked=expectError(@() t.propose(sprintf('function y=fcn(a,b)\ny=a+b;\nend')),'MatlabAI:SimInterface');
    if includeModel
        app=MatlabAIAssistant('off'); cleanupApp=onCleanup(@() delete(app));
        waitReady(app,30); app.SimulinkTarget.Value=model;
        app.Mode.Value='sim_edit'; app.Mode.ValueChangedFcn(app.Mode,[]);
        assert(isequal(app.Scope.ItemsData,{'file','selection'}) && strcmp(app.CaptureButton.Text,'读取目标模型'));
        app.Mode.Value='complete'; app.Mode.ValueChangedFcn(app.Mode,[]);
        assert(strcmp(app.Scope.Value,'cursor') && numel(app.Scope.ItemsData)==3);
        checks.mode_switch_restores_editor_scope=true;
        app.ask('解释选中的 MATLAB Function 模块及其输入输出，不修改。','sim_explain','selection');
        waitReady(app,75); assert(isempty(app.LastError),app.LastError);
        assert(isempty(app.LastResponse.replacement)); checks.real_explanation=true;
        app.ask('把 Gain 模块的 Gain 参数改为 6，仅修改这一项。','sim_edit','file');
        waitReady(app,75); assert(isempty(app.LastError),app.LastError);
        assert(strcmp(get_param([model '/Gain'],'Gain'),'2')); app.apply;
        assert(strcmp(get_param([model '/Gain'],'Gain'),'6')); app.restore; checks.real_parameter_preview_apply_restore=true;
        app.ask('把选中模块改成 y 等于 u 的三次方，保留函数接口。','sim_function','selection');
        waitReady(app,75); assert(isempty(app.LastError),app.LastError);
        assert(strcmp(chart.Script,original)); app.apply; assert(~strcmp(chart.Script,original)); app.restore;
        assert(strcmp(chart.Script,original)); checks.real_function_preview_apply_restore=true;
        app.ask('在 Gain 到 Output 的连接中插入一个名为 AddedGain 的 Gain 模块，增益为 3。保留到 Branch 的支路和其他模块。','sim_edit','file');
        waitReady(app,75); assert(isempty(app.LastError),app.LastError);
        before=ai_simulink_snapshot(model); app.apply;
        assert(strcmp(get_param([model '/AddedGain'],'Gain'),'3'));
        app.restore; assert(strcmp(jsonencode(ai_simulink_snapshot(model)),jsonencode(before)));
        checks.real_add_rewire_branch_restore=true;
        screenshot=fullfile(fileparts(fileparts(mfilename('fullpath'))),'output','simulink-assistant-test.png');
        exportapp(app.Figure,screenshot);
    end
    empty=['ai_sim_empty_' strrep(char(java.util.UUID.randomUUID),'-','')]; new_system(empty);
    cleanupEmpty=onCleanup(@() close_system(empty,0));
    t=AISimulinkTransaction(empty,'sim_edit','file');
    t.propose(jsonencode(struct('operations',{{struct('op','add','path','First','kind','Constant','position',[20 20 60 60])}})));
    t.apply; t.restore; s=ai_simulink_snapshot(empty); assert(isempty(s.blocks)); checks.empty_model_add_restore=true;
    result=jsonencode(struct('ok',true,'checks',checks));
catch exception
    result=jsonencode(struct('ok',false,'checks',checks,'error',exception.message,'stack',{exception.stack}));
end
root=fileparts(fileparts(mfilename('fullpath')));
suffix='local'; if includeModel, suffix='real'; end
fid=fopen(fullfile(root,'output',['test-simulink-' suffix '.json']),'w','n','UTF-8');
if fid>=0, fwrite(fid,unicode2native(result,'UTF-8'),'uint8'); fclose(fid); end
end
function value=expectError(callback,id)
value=false;
try, callback(); catch e, assert(strcmp(e.identifier,id),'Unexpected: %s [%s]',e.message,e.identifier); value=true; end
assert(value,'Expected rejection.');
end
function waitReady(app,seconds)
started=tic;
while (app.IsBusy || app.IsLoadingModels) && toc(started)<seconds, pause(0.1); end
assert(~app.IsBusy && ~app.IsLoadingModels,'后台任务未及时结束。');
end
