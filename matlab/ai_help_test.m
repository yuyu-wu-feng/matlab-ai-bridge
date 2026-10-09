function result=ai_help_test(includeModel)
if nargin<1, includeModel=false; end
checks=struct;
folder=tempname; mkdir(folder);
cleanupFolder=onCleanup(@() rmdir(folder,'s'));
app=MatlabAIAssistant('off',folder);
cleanupApp=onCleanup(@() delete(app));
original=matlab.desktop.editor.getActive;
if ~isempty(original), originalText=original.Text; else, originalText=''; end
try
    c=ai_help_context('interp1 和 spline 的区别是什么？');
    assert(all(ismember({'interp1','spline'},{c.documents.topic})));
    checks.local_comparison_sources=true;
    c=ai_help_context('MATLAB 有哪些插值函数？');
    assert(ismember('interp1',{c.documents.topic}));
    checks.chinese_topic_lookup=true;
    c=ai_help_context('我装了哪些工具箱？');
    assert(any(strcmp({c.products.name},'MATLAB')) && ~isempty(c.release));
    checks.installed_inventory=true;
    c=ai_help_context('zzMissingFunction123');
    assert(isempty(c.documents)); checks.missing_help_explicit=true;
    c=ai_help_context('参数是什么意思','interp1 的作用');
    assert(ismember('interp1',{c.documents.topic})); checks.followup_sources=true;
    c=ai_help_context('ai_help_test 的用法');
    assert(isempty(c.documents)); checks.user_files_not_read=true;
    store=AIConversationStore(folder);
    store.add('private code','generate','test',struct('explanation','','replacement','PRIVATE_EDITOR'));
    store.add('interp1 是什么','help','test',struct('explanation','本机帮助 [H1]','replacement',''));
    history=store.context(true);
    assert(numel(history)==1 && strcmp(history{1}.mode,'help') && isempty(history{1}.replacement));
    restored=AIConversationStore(folder); restored.load(store.ID);
    assert(strcmp(restored.Turns(end).mode,'help')); checks.help_history_persists_and_filters_code=true;
    waitReady(app,30);
    app.Mode.Value='help'; app.Question.Value={'interp1 和 spline 的区别是什么？'};
    app.capture;
    assert(isempty(app.Transaction) && ~isempty(app.HelpContext.documents));
    assert(contains(strjoin(string(app.HelpSources.Value)), 'interp1'));
    checks.local_sources_available_without_model=true;
    if includeModel
        app.ask('interp1 和 spline 的区别是什么？简短说明，不要给代码。','help','file');
        waitReady(app,75);
        assert(isempty(app.LastError),app.LastError);
        assert(isempty(app.LastResponse.replacement) && isempty(app.GeneratedText));
        assert(strcmp(app.InsertButton.Enable,'off') && strcmp(app.NewDocumentButton.Enable,'off') && strcmp(app.ApplyButton.Enable,'off'));
        assert(contains(app.LastResponse.explanation,'H1') || contains(app.LastResponse.explanation,'H2'));
        assert(isequal(app.Tabs.SelectedTab,app.HelpTab));
        checks.real_help_answer=true; checks.generation_disabled=true;
        checks.elapsed_seconds=app.LastResponse.elapsed_seconds;
    end
    if ~isempty(original), assert(strcmp(original.Text,originalText)); end
    checks.editor_unchanged=true;
    result=jsonencode(struct('ok',true,'checks',checks));
catch exception
    result=jsonencode(struct('ok',false,'checks',checks,'error',exception.message,'stack',{exception.stack}));
end
end

function waitReady(app,seconds)
started=tic;
while (app.IsBusy || app.IsLoadingModels) && toc(started)<seconds, pause(0.1); end
assert(~app.IsBusy && ~app.IsLoadingModels,'助手未及时结束请求。');
end
