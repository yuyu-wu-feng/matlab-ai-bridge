function result = ai_workflow_test(useModel)
if nargin<1, useModel=false; end
checks=struct;
root=fileparts(fileparts(mfilename('fullpath')));
folder=fullfile(root,'output',['workflow-test-' char(java.util.UUID.randomUUID)]);
mkdir(folder);
cleanupFolder=onCleanup(@() rmdir(folder,'s'));
original=matlab.desktop.editor.getActive;
restoreOriginal=onCleanup(@() activate(original));
app=[];
try
    store=AIConversationStore(folder);
    response=struct('explanation','第一版','replacement',sprintf('x = [1 2 3];\ny = x.^2;\n'));
    store.add('生成平方示例','generate','test',response);
    id=store.ID; originalHistory=fileread(fullfile(folder,[id '.json']));
    loaded=AIConversationStore(folder); loaded.load(id);
    assert(strcmp(loaded.Turns(1).replacement,response.replacement));
    loaded.add('加中文注释','generate','test',response);
    assert(~strcmp(loaded.ID,id) && strcmp(fileread(fullfile(folder,[id '.json'])),originalHistory));
    checks.history_roundtrip_and_fork=true;
    memory=AIConversationStore('');
    for k=1:9, memory.add(num2str(k),'generate','test',response); end
    context=memory.context;
    assert(numel(context)==6 && strcmp(context{1}.question,'4'));
    checks.context_bounded_to_recent_turns=true;
    badID=char(java.util.UUID.randomUUID);
    writeText(fullfile(folder,[badID '.json']),'{invalid');
    checks.corrupt_history_preserved=expectError(@() loaded.load(badID),'MatlabAI:HistoryFile');
    assert(strcmp(fileread(fullfile(folder,[badID '.json'])),'{invalid'));

    sentinel=fullfile(folder,'must-not-execute.txt');
    report=ai_check_code(sprintf('fid=fopen(''%s'',''w''); fclose(fid);\nx = ;\n',strrep(sentinel,"'","''")));
    assert(report.count>0 && ~isfile(sentinel));
    checks.static_check_without_execution=true;
    baseline=sprintf('a=1;\nb=2;\nc=3;\n');
    changed=sprintf('a=10;\nb=2;\nc=30;\n');
    blocks=ai_change_blocks(baseline,changed);
    assert(numel(blocks)==2);
    doc=matlab.desktop.editor.newDocument(baseline);
    cleanupDoc=onCleanup(@() closeOwned(doc));
    transaction=AIEditorTransaction(doc,'edit','file'); transaction.propose(changed);
    transaction.selectChanges(blocks,[true false]); transaction.apply;
    assert(strcmp(char(doc.Text),sprintf('a=10;\nb=2;\nc=3;\n')));
    transaction.restore;
    assert(strcmp(char(doc.Text),baseline));
    checks.partial_changes_and_restore=true;
    assert(isempty(ai_change_blocks(baseline,baseline)));
    crlf=sprintf('a=1;\r\nb=2;\r\n');
    crlfBlocks=ai_change_blocks(crlf,sprintf('a=10;\r\nb=2;\r\n'));
    assert(strcmp(crlfBlocks.replacement,sprintf('a=10;\r\n')));
    checks.change_blocks_preserve_line_endings=true;

    app=MatlabAIAssistant('off',folder);
    cleanupApp=onCleanup(@() deleteIfValid(app));
    waitReady(app,35);
    app.loadConversation(id);
    app.useVersion(1);
    doc.Selection=[2 1 2 1]; doc.makeActive;
    app.insertGenerated(false);
    assert(strcmp(char(doc.Text),baseline) && strcmp(app.ApplyButton.Text,'确认插入'));
    checks.insertion_preview_does_not_write=true;
    doc.Text=[baseline '% user change'];
    checks.preview_conflict_rejected=expectError(@() app.apply,'MatlabAI:Conflict');
    doc.Text=baseline; doc.Selection=[2 1 2 1]; doc.makeActive;
    app.insertGenerated(false);
    app.chooseChanges(false(numel(app.ChangeBlocks),1));
    checks.empty_change_selection_rejected=expectError(@() app.apply,'MatlabAI:NoSelection');
    app.chooseChanges(true(numel(app.ChangeBlocks),1)); app.apply;
    assert(contains(char(doc.Text),response.replacement));
    app.restore; assert(strcmp(char(doc.Text),baseline));
    checks.confirm_insert_and_restore=true;
    app.Question.Value={'关闭后要恢复的草稿'};
    delete(app);
    app=MatlabAIAssistant('off',folder);
    cleanupApp2=onCleanup(@() deleteIfValid(app));
    waitReady(app,35);
    assert(numel(app.Store.Turns)>=1);
    assert(strcmp(strjoin(string(app.Question.Value),newline),'关闭后要恢复的草稿'));
    assert(isempty(app.Transaction) && isempty(app.LastApplied));
    checks.reopen_history_and_draft_without_editor_transaction=true;
    app.newConversation;
    assert(isempty(app.Store.Turns));
    assert(isfile(fullfile(folder,[id '.json'])));
    checks.new_conversation_preserves_saved_history=true;

    if useModel
        app.ask('生成一个简单 MATLAB 脚本，包含 session_marker=72419; x=[1 2 3]; y=x.^2;，保留这些变量，不运行、不绘图。','generate','file');
        sawPartial=waitReady(app,210);
        assert(isempty(app.LastError),app.LastError);
        assert(contains(app.GeneratedText,'72419'));
        assert(app.StreamChunks>1 && sawPartial,'没有观察到请求完成前的流式内容。');
        assert(isfield(app.CheckReport,'count') && ~isnan(app.CheckReport.count));
        checks.real_streaming_and_static_check=true;
        app.ask('保留上一版的标记和值以及计算，在后面增加 total=sum(y)，并加中文注释。','generate','file');
        assert(app.RequestHistoryCount==1);
        waitReady(app,210); assert(isempty(app.LastError),app.LastError);
        assert(contains(app.GeneratedText,'72419') && contains(app.GeneratedText,'total'));
        checks.real_followup_keeps_prior_code=true;
        app.Question.Value={'我把 y 的计算改成 x*x 后报矩阵乘法维度不正确。请改回逐元素平方，并保留其他功能。'};
        app.repairFromError;
        assert(app.RequestHistoryCount==2);
        waitReady(app,210); assert(isempty(app.LastError),app.LastError);
        assert(contains(app.GeneratedText,'.^') && contains(app.GeneratedText,'72419') && contains(app.GeneratedText,'total'));
        assert(numel(app.Store.Turns)==3);
        assert(strcmp(char(doc.Text),baseline),'生成和修复不应自动写入编辑器。');
        checks.real_error_repair_keeps_full_script=true;
        app.useVersion(2);
        assert(numel(app.Store.Turns)==2 && ~app.Store.Owned);
        checks.branch_from_earlier_version=true;
    end
    result=jsonencode(struct('ok',true,'checks',checks,'real_model_tested',useModel));
catch exception
    result=jsonencode(struct('ok',false,'checks',checks,'error',exception.message,'stack',{exception.stack}));
end
end

function sawPartial=waitReady(app,seconds)
sawPartial=false; started=tic;
while (app.IsLoadingModels || app.IsBusy) && toc(started)<seconds
    if app.IsBusy && app.StreamChunks>0
        sawPartial=true;
        assert(strcmp(app.InsertButton.Enable,'off') && strcmp(app.ApplyButton.Enable,'off'));
    end
    pause(0.05);
end
assert(~app.IsLoadingModels && ~app.IsBusy,'后台任务未及时完成。');
end

function yes=expectError(callback,id)
yes=false;
try, callback(); catch exception
    assert(strcmp(exception.identifier,id),'Unexpected error: %s',exception.message); yes=true;
end
assert(yes,'Expected operation to be rejected.');
end

function writeText(path,value)
fid=fopen(path,'w','n','UTF-8'); cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(value,'UTF-8'),'uint8');
end

function deleteIfValid(app)
if ~isempty(app) && isvalid(app), delete(app); end
end
function closeOwned(doc)
if doc.Opened, doc.closeNoPrompt; end
end
function activate(doc)
if ~isempty(doc) && doc.Opened, doc.makeActive; end
end
