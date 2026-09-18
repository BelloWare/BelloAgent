import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { memo, useEffect, useMemo, useRef, useState, type ComponentPropsWithoutRef } from 'react';
import type { Components, ExtraProps } from 'react-markdown';
import { addMarkdownCopyTargets, type MarkdownCopySelection, type MarkdownCopyTarget, type MarkdownNode } from './markdown-copy.ts';
const HighlightedCode = memo(function HighlightedCode({children,className}:ComponentPropsWithoutRef<'code'>) {
  const text=typeof children==='string'?children:'',language=/^language-([a-z0-9]+)$/.exec(className??'')?.[1];
  const [highlight,setHighlight]=useState<{text:string;html:string}|null>(null);
  useEffect(()=>{
    if(!language || text.length>16384)return;
    let active=true;
    const timer=setTimeout(()=>{void import('./highlight.ts').then(({highlightCode})=>{
      if(active){const html=highlightCode(text,language);setHighlight(html===null?null:{text,html});}
    });},120);
    return ()=>{active=false;clearTimeout(timer);};
  },[text,language]);
  return highlight?.text===text?<code className={className} dangerouslySetInnerHTML={{__html:highlight.html}}/>:<code className={className}>{children}</code>;
});
const components = {
  code: HighlightedCode,
  img: ({ alt }: ComponentPropsWithoutRef<'img'>) => <span className="notice">[Image not loaded{alt ? `: ${alt}` : ''}]</span>,
  a: ({ href, children }: ComponentPropsWithoutRef<'a'>) => href ? <a href={href} rel="noreferrer noopener">{children}</a> : <span>{children}</span>,
};

function CopyButton({ target, copy }: { target: MarkdownCopyTarget; copy: (selection: MarkdownCopySelection) => Promise<boolean> }) {
  const [feedback, setFeedback] = useState<{ key: string; state: 'pending' | 'copied' | 'failed' } | null>(null);
  const key = target.source + JSON.stringify(target.ranges), current = useRef(key), timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  current.current = key;
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); current.current = ''; }, []);
  const state = feedback?.key === key ? feedback.state : null;
  const label = state === 'copied' ? 'Copied' : state === 'failed' ? 'Try again' : 'Copy';
  return <span className="markdown-copy-control">
    <button type="button" className={`markdown-copy-button${state === 'copied' ? ' copied' : ''}`} aria-label={target.label} title={target.label} disabled={state === 'pending'} onClick={() => {
      if (timer.current) clearTimeout(timer.current);
      setFeedback({ key, state: 'pending' });
      void copy({ source: target.source, ranges: target.ranges }).then(success => {
        if (current.current !== key) return;
        setFeedback({ key, state: success ? 'copied' : 'failed' });
        timer.current = setTimeout(() => setFeedback(null), 2_000);
      }, () => { if (current.current === key) setFeedback({ key, state: 'failed' }); });
    }}>
      <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25" aria-hidden="true">
        {state === 'copied' ? <path d="m3 8 3 3 7-7" /> : <><rect x="5.5" y="5.5" width="8" height="8" rx="1.5" /><path d="M10.5 3.5V3A1.5 1.5 0 0 0 9 1.5H3A1.5 1.5 0 0 0 1.5 3v6A1.5 1.5 0 0 0 3 10.5h.5" /></>}
      </svg>
      <span aria-hidden="true">{label}</span>
    </button>
    <span className="visually-hidden" role="status" aria-live="polite">{state === 'copied' ? 'Copied to clipboard' : state === 'failed' ? 'Could not copy. Content may have changed; try again.' : ''}</span>
  </span>;
}

export function safeURL(value: string): string {
  try { const url = new URL(value); return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password ? url.href : ''; }
  catch { return ''; }
}
export function SafeMarkdown({ text, onCopy }: { text: string; onCopy?: (selection: MarkdownCopySelection) => Promise<boolean> }) {
  const source = useRef(text); source.current = text;
  const presentation = useMemo(() => {
    if (!onCopy) return { components, plugins: [remarkGfm] };
    const targets = new Map<string, MarkdownCopyTarget>();
    const copyPlugin = () => (tree: MarkdownNode): void => addMarkdownCopyTargets(tree, source.current, targets);
    const targetFor = (node: ExtraProps['node']): MarkdownCopyTarget | undefined => {
      const key = node?.properties['data-copy-key'];
      return typeof key === 'string' ? targets.get(key) : undefined;
    };
    const heading = (tag: 'h1' | 'h2' | 'h3' | 'h4' | 'h5' | 'h6') => function Heading({ node, children }: ComponentPropsWithoutRef<'h1'> & ExtraProps) {
      const Tag = tag, target = targetFor(node);
      return <Tag className={target ? 'copyable-heading' : undefined}>{children}{target && <CopyButton target={target} copy={onCopy} />}</Tag>;
    };
    const copyComponents: Components = {
      ...components,
      h1: heading('h1'), h2: heading('h2'), h3: heading('h3'), h4: heading('h4'), h5: heading('h5'), h6: heading('h6'),
      span: ({ node, children }) => {
        const target = targetFor(node);
        return target ? <span className="markdown-introduction-copy"><CopyButton target={target} copy={onCopy} /></span> : <span>{children}</span>;
      },
      pre: ({ node, children }) => {
        const code = node?.children.find(child => child.type === 'element' && child.tagName === 'code');
        const target = code?.type === 'element' ? targetFor(code) : undefined;
        const classes = code?.type === 'element' ? code.properties?.className : undefined;
        const language = (Array.isArray(classes) ? classes : []).map(String).map(name => /^language-([a-z0-9+#-]+)$/i.exec(name)?.[1]).find(Boolean) ?? null;
        return target ? <div className="copyable-code"><div className="code-copy-toolbar">{language && <span className="code-lang" aria-label={`Language ${language}`}>{language}</span>}<CopyButton target={target} copy={onCopy} /></div><pre>{children}</pre></div> : <pre>{children}</pre>;
      },
    };
    return { components: copyComponents, plugins: [remarkGfm, copyPlugin] };
  // Component identities survive streaming updates so keyboard focus and code
  // highlight state stay attached to the same visible block.
  }, [onCopy]);
  return <Markdown skipHtml remarkPlugins={presentation.plugins} urlTransform={safeURL} components={presentation.components}>{text}</Markdown>;
}
