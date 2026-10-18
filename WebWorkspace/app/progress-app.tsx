"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { addUnit, deleteUnit, renameUnit, reorder, setCompleted, setPaused } from "../lib/content-progress/commands";
import { projectProgress } from "../lib/content-progress/projection";
import { BrowserProgressRepository, type ProgressDraft } from "../lib/content-progress/repository";
import { decodePlanUnits } from "../lib/content-progress/plan-provider";
import type { ProgressProject } from "../lib/content-progress/domain";
import "./progress.css";

export function ProgressApp() {
  const [store, setStore] = useState<BrowserProgressRepository | null>(null);
  const [projects, setProjects] = useState<ProgressProject[]>([]);
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const [draft, setDraft] = useState<ProgressDraft | null>(null);
  const [newTitle, setNewTitle] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [apiKey, setApiKey] = useState("");
  const [models, setModels] = useState<string[]>([]);
  const [model, setModel] = useState("");
  const [generating, setGenerating] = useState(false);
  const draftSaveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const operationPending = useRef(false);
  const generationID = useRef(0);
  const generationController = useRef<AbortController | null>(null);

  useEffect(() => {
    let cancelled = false;
    let opened: BrowserProgressRepository | null = null;
    BrowserProgressRepository.open().then(async (repository) => {
      opened = repository;
      const [savedProjects, savedDrafts] = await Promise.all([repository.projects(), repository.drafts()]);
      if (cancelled) { repository.close(); return; }
      setStore(repository);
      setProjects(savedProjects);
      setDraft(savedDrafts[0] ?? null);
      setLoading(false);
    }).catch((cause) => { if (!cancelled) { setError(String(cause)); setLoading(false); } });
    return () => { cancelled = true; opened?.close(); };
  }, []);

  useEffect(() => {
    fetch("/api/progress-plan", { cache: "no-store" }).then((response) => response.json())
      .then((value: { models?: unknown }) => {
        const available = Array.isArray(value.models) ? value.models.filter((item): item is string => typeof item === "string") : [];
        setModels(available);
        setModel(available[0] ?? "");
      }).catch(() => setModels([]));
  }, []);

  useEffect(() => {
    if (!store || !draft) return;
    draftSaveTimer.current = setTimeout(() => { store.saveDraft(draft).catch((cause) => setError(String(cause))); }, 200);
    return () => { if (draftSaveTimer.current) clearTimeout(draftSaveTimer.current); };
  }, [draft, store]);

  const selected = projects.find((project) => project.id === selectedID) ?? null;
  const selectedProgress = selected ? projectProgress(selected) : null;
  useEffect(() => {
    if (!selected || selected.units.length <= 6) return;
    const currentID = projectProgress(selected).currentUnitID;
    if (currentID) document.getElementById(`progress-unit-${currentID}`)?.scrollIntoView({ block: "center" });
  }, [selected]);
  async function refresh() { if (store) setProjects(await store.projects()); }
  async function startDraft() {
    if (!store) return;
    if (draft) return;
    try {
      const saved = await store.drafts();
      if (saved[0]) { setDraft(saved[0]); return; }
    } catch (cause) { setError(String(cause)); return; }
    const timestamp = new Date().toISOString();
    const next: ProgressDraft = { id: crypto.randomUUID(), name: "", outlineText: "", courseURL: null, units: [], createdAt: timestamp, updatedAt: timestamp };
    try { await store.saveDraft(next); setDraft(next); setError(""); } catch (cause) { setError(String(cause)); }
  }
  function editDraft(change: Partial<ProgressDraft>) {
    cancelGeneration();
    setDraft((current) => current ? { ...current, ...change, updatedAt: new Date().toISOString() } : null);
  }
  function cancelGeneration() {
    generationID.current += 1;
    generationController.current?.abort();
    generationController.current = null;
    setGenerating(false);
  }
  async function generate() {
    if (!draft) return;
    if (draft.units.length > 0 && !window.confirm("用新的 AI 结果替换现有学习单元？生成失败时草稿保持不变。")) return;
    if (!apiKey || !model) { setError("请先输入 API Key，并配置可用的 AI 模型。"); return; }
    cancelGeneration();
    const requestID = generationID.current;
    const controller = new AbortController();
    generationController.current = controller;
    setGenerating(true);
    setError("");
    try {
      const response = await fetch("/api/progress-plan", {
        method: "POST",
        signal: controller.signal,
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
        body: JSON.stringify({ model, name: draft.name, outlineText: draft.outlineText, courseURL: draft.courseURL }),
      });
      const result: unknown = await response.json();
      if (!response.ok) throw new Error((result as { error?: string }).error ?? "AI 生成失败");
      const titles = decodePlanUnits(result);
      if (generationID.current !== requestID) return;
      setDraft((current) => current === draft ? {
        ...current,
        units: titles.map((title) => ({ id: crypto.randomUUID(), title })),
        updatedAt: new Date().toISOString(),
      } : current);
    } catch (cause) {
      if (generationID.current === requestID) setError(String(cause));
    } finally {
      if (generationID.current === requestID) { setGenerating(false); generationController.current = null; }
    }
  }
  async function confirm() {
    if (!store || !draft) return;
    cancelGeneration();
    if (draftSaveTimer.current) clearTimeout(draftSaveTimer.current);
    try {
      await store.saveDraft(draft);
      const project = await store.confirmDraft(draft.id);
      await refresh(); setSelectedID(project.id); setDraft(null); setError("");
    } catch (cause) { setError(String(cause)); }
  }
  async function cancel() {
    if (!store || !draft) return;
    cancelGeneration();
    if (draftSaveTimer.current) clearTimeout(draftSaveTimer.current);
    try { await store.removeDraft(draft.id); setDraft(null); setError(""); } catch (cause) { setError(String(cause)); }
  }
  async function saveAndClose() {
    if (!store || !draft) return;
    cancelGeneration();
    if (draftSaveTimer.current) clearTimeout(draftSaveTimer.current);
    try { await store.saveDraft(draft); setDraft(null); setError(""); }
    catch (cause) { setError(String(cause)); }
  }
  async function run(change: () => ProgressProject): Promise<boolean> {
    if (!store || operationPending.current) return false;
    operationPending.current = true;
    try {
      const next = change();
      await store.saveProject(next);
      await refresh();
      setError("");
      return true;
    } catch (cause) {
      setError(String(cause));
      return false;
    } finally { operationPending.current = false; }
  }
  function move(id: string, direction: -1 | 1) {
    if (!selected) return;
    const ids = selected.units.map((unit) => unit.id);
    const index = ids.indexOf(id), target = index + direction;
    if (target < 0 || target >= ids.length) return;
    [ids[index], ids[target]] = [ids[target], ids[index]];
    void run(() => reorder(selected, ids));
  }
  function dropUnit(sourceID: string, destinationID: string) {
    if (!selected || sourceID === destinationID) return;
    const ids = selected.units.map((unit) => unit.id);
    const source = ids.indexOf(sourceID), destination = ids.indexOf(destinationID);
    if (source < 0 || destination < 0) return;
    ids.splice(destination, 0, ids.splice(source, 1)[0]);
    void run(() => reorder(selected, ids));
  }
  function moveDraftUnit(id: string, direction: -1 | 1) {
    if (!draft) return;
    const units = [...draft.units];
    const index = units.findIndex((unit) => unit.id === id);
    const target = index + direction;
    if (target < 0 || target >= units.length) return;
    [units[index], units[target]] = [units[target], units[index]];
    editDraft({ units });
  }

  if (loading) return <main className="progress-shell progress-shell--loading"><div className="progress-loading" role="status">
    <span className="progress-loading-mark" aria-hidden="true" /><small>SELF STUDY STUDIO</small><p>正在读取本地项目</p>
  </div></main>;
  if (!store) return <main className="progress-shell progress-shell--loading"><div className="progress-fatal"><small>LOCAL STORAGE</small><h1>本地项目没有打开。</h1><p role="alert">{error}</p></div></main>;
  return <main className="progress-shell">
    <a className="progress-skip-link" href="#progress-content">跳到主要内容</a>
    <header className="progress-site-header">
      <Link className="progress-brand" href="/" aria-label="Self Study Studio 首页"><span className="progress-brand-mark" aria-hidden="true" /><strong>self study studio</strong></Link>
      <span className="progress-local-status"><i aria-hidden="true" />仅保存在此浏览器</span>
    </header>
    {error && !draft && <p role="alert" className="progress-error">{error}</p>}
    {selected ? <section id="progress-content" className="progress-detail" aria-label="项目详情">
      <button className="progress-link" onClick={() => setSelectedID(null)}><span aria-hidden="true">←</span> 返回所有项目</button>
      <div className="progress-detail-hero"><div><small>{selected.isPaused ? "PROJECT PAUSED" : "CURRENT PROJECT"}</small><h1>{selected.name}</h1><p>每次只推进一个单元。完成后，下一步会自然接上。</p></div>
        <button className="progress-secondary" onClick={() => void run(() => setPaused(selected, !selected.isPaused))}>{selected.isPaused ? "恢复项目" : "暂停项目"}</button></div>
      <Summary project={selected} variant="detail" />
      <div className="progress-section-heading"><div><small>CONTENT PATH</small><h2>学习单元</h2></div><p>完成一项，进度和当前单元会一起更新。</p></div>
      {selected.units.length === 0 && <div className="progress-inline-empty"><p>尚无学习单元。</p><span>在下方添加第一项，让项目开始移动。</span></div>}
      <ol className="progress-units">{selected.units.map((unit, index) => <li className={unit.isCompleted ? "is-complete" : unit.id === selectedProgress?.currentUnitID ? "is-current" : "is-upcoming"} key={unit.id} id={`progress-unit-${unit.id}`} draggable
        onDragStart={(event) => event.dataTransfer.setData("text/plain", unit.id)}
        onDragOver={(event) => event.preventDefault()}
        onDrop={(event) => { event.preventDefault(); dropUnit(event.dataTransfer.getData("text/plain"), unit.id); }}>
        <span className="progress-unit-index" aria-hidden="true">{String(index + 1).padStart(2, "0")}</span>
        <label><input type="checkbox" checked={unit.isCompleted} disabled={selected.isPaused} onChange={(event) => void run(() => setCompleted(selected, unit.id, event.target.checked))} /><span className="progress-unit-copy"><small>{unit.isCompleted ? "已完成" : unit.id === selectedProgress?.currentUnitID ? "当前" : "待学习"}</small><span>{unit.title}</span></span></label>
        <div className="progress-unit-actions"><button aria-label={`上移 ${unit.title}`} disabled={index === 0} onClick={() => move(unit.id, -1)}>↑</button>
          <button aria-label={`下移 ${unit.title}`} disabled={index === selected.units.length - 1} onClick={() => move(unit.id, 1)}>↓</button>
          <button onClick={() => { const title = window.prompt("修改学习单元", unit.title); if (title !== null) void run(() => renameUnit(selected, unit.id, title)); }}>修改</button>
          <button className="progress-danger" onClick={() => { if (window.confirm(`删除「${unit.title}」及其完成状态？`)) void run(() => deleteUnit(selected, unit.id)); }}>删除</button></div>
      </li>)}</ol>
      <div className="progress-add"><input aria-label="新学习单元标题" placeholder="添加学习单元" value={newTitle} onChange={(event) => setNewTitle(event.target.value)} />
        <button className="progress-primary" disabled={!newTitle.trim()} onClick={() => { void run(() => addUnit(selected, newTitle)).then((saved) => { if (saved) setNewTitle(""); }); }}>添加单元</button></div>
    </section> : <section id="progress-content" className="progress-home" aria-label="项目首页">
      <div className="progress-hero"><div><small>YOUR LEARNING, IN MOTION</small><h1>把要学的内容，<span>变成下一步。</span></h1><p>用一条清楚的内容路径记住进度。你决定什么算完成，系统负责把下一步带回来。</p></div><button className="progress-primary progress-hero-action" onClick={() => void startDraft()}>创建学习项目</button></div>
      <div className="progress-projects-heading"><div><small>YOUR PROJECTS</small><h2>从上次停下的地方继续。</h2></div><p><strong>{projects.length}</strong> 个项目<br />仅保存在此浏览器</p></div>
      {projects.length === 0 && <div className="progress-empty"><span className="progress-empty-mark" aria-hidden="true" /><div><small>START HERE</small><h2>你的第一条学习路径，从一个项目开始。</h2><p>输入主题或粘贴课程目录，确认后再正式开始。</p></div><button className="progress-secondary" onClick={() => void startDraft()}>创建第一个项目</button></div>}
      <div className="progress-project-list">{projects.map((project) => <button className="progress-card" key={project.id} onClick={() => setSelectedID(project.id)}>
        <span className="progress-card-topline"><small>{project.isPaused ? "PROJECT PAUSED" : "LEARNING PROJECT"}</small><span>打开项目 <i aria-hidden="true">→</i></span></span><strong>{project.name}</strong><Summary project={project} />
      </button>)}</div>
    </section>}
    {draft && <div className="progress-overlay"><div role="dialog" aria-modal="true" aria-label="创建学习项目" className="progress-dialog">
      <header className="progress-dialog-heading"><div><small>NEW PROJECT</small><h2>把一个想学的东西，变成可以开始的路径。</h2></div><p>先生成或整理学习单元，由你确认后再创建项目。</p></header>
      {error && <p role="alert" className="progress-error">{error}</p>}
      <label>项目名称<input autoFocus placeholder="例如：学习 React" value={draft.name} onChange={(event) => editDraft({ name: event.target.value })} /></label>
      <label>课程链接（可选）<input type="url" placeholder="https://…" value={draft.courseURL ?? ""} onChange={(event) => editDraft({ courseURL: event.target.value || null })} /></label>
      <label>课程目录（可选，优先使用）<textarea placeholder="粘贴课程章节或目录" value={draft.outlineText} onChange={(event) => editDraft({ outlineText: event.target.value })} /></label>
      <p className="progress-field-note">当前链接尚不能自动读取；使用链接时请同时粘贴目录。也可只用项目名称生成。</p>
      <div className="progress-ai-config"><label>AI 模型<select value={model} onChange={(event) => setModel(event.target.value)} disabled={models.length === 0}>
        {models.length === 0 ? <option value="">本站尚未配置 AI 服务</option> : models.map((value) => <option key={value} value={value}>{value}</option>)}
      </select></label><label>API Key（仅保存在当前页面内存）<input type="password" autoComplete="off" value={apiKey} onChange={(event) => setApiKey(event.target.value)} /></label>
        <button disabled={generating || !draft.name.trim()} onClick={() => void generate()}>{generating ? "正在生成…" : draft.units.length > 0 ? "重新生成" : "AI 生成内容结构"}</button>
        {generating && <button onClick={cancelGeneration}>取消生成</button>}
      </div>
      <div className="progress-dialog-section-heading"><small>CONTENT PATH</small><h3>学习单元</h3></div><ol>{draft.units.map((unit, index) => <li key={unit.id}><span aria-hidden="true">{String(index + 1).padStart(2, "0")}</span><input aria-label={`第 ${index + 1} 个单元标题`} value={unit.title} onChange={(event) => editDraft({ units: draft.units.map((item) => item.id === unit.id ? { ...item, title: event.target.value } : item) })} /><button aria-label={`上移第 ${index + 1} 个单元`} disabled={index === 0} onClick={() => moveDraftUnit(unit.id, -1)}>↑</button><button aria-label={`下移第 ${index + 1} 个单元`} disabled={index === draft.units.length - 1} onClick={() => moveDraftUnit(unit.id, 1)}>↓</button><button className="progress-danger" onClick={() => editDraft({ units: draft.units.filter((item) => item.id !== unit.id) })}>删除</button></li>)}</ol>
      <button className="progress-secondary" onClick={() => editDraft({ units: [...draft.units, { id: crypto.randomUUID(), title: "" }] })}>添加单元</button>
      <div className="progress-dialog-actions"><button onClick={() => void cancel()}>取消</button><button onClick={() => void saveAndClose()}>保存草稿并返回</button><button className="progress-primary" disabled={!draft.name.trim() || draft.units.some((unit) => !unit.title.trim())} onClick={() => void confirm()}>确认创建</button></div>
    </div></div>}
    <footer><span>Self Study Studio · 本地内容进度</span><a href="/legacy">查看旧版学习记录 <i aria-hidden="true">↗</i></a></footer>
  </main>;
}

function Summary({ project, variant = "card" }: { project: ProgressProject; variant?: "card" | "detail" }) {
  const value = projectProgress(project);
  const current = project.units.find((unit) => unit.id === value.currentUnitID);
  const next = project.units.find((unit) => unit.id === value.nextUnitID);
  return <div className={`progress-summary progress-summary--${variant}`}><span className="progress-summary-ghost" aria-hidden="true">{value.percentage}%</span><div className="progress-summary-number"><strong>{value.percentage}<i>%</i></strong><span>{value.completed} / {value.total} 已完成</span></div>
    <div className="progress-meter" role="progressbar" aria-label={`${project.name} 完成进度`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={value.percentage}><span style={{ width: `${value.percentage}%` }} /></div>
    <div className="progress-summary-steps"><div><small>正在进行</small><p>{current?.title ?? (value.isAllCompleted ? "全部完成" : "尚无学习单元")}</p></div><div><small>接下来</small><p>{next?.title ?? "无下一单元"}</p></div></div>
  </div>;
}
