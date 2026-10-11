import React, {useEffect, useMemo, useRef, useState} from 'react';
import {AbsoluteFill, Audio, Easing, Img, cancelRender, continueRender, delayRender, interpolate, spring, staticFile, useCurrentFrame} from 'remotion';

// Launch cut in the site's language: paper, ink, the orange dot, Bree Serif and the landscape.
// Fast one-second beats on a 120 bpm bed (a beat every 15 frames at 30 fps).

export const FPS2 = 30;
export const LAUNCH2_SECONDS = 41;
const f = (sec: number) => Math.round(sec * FPS2);
const paper = '#F9FAF7', ink = '#202A2E', dot = '#EE5F27', mute = 'rgba(32,42,46,.45)';
const serif = '"Bree Serif", serif', sans = '"DM Sans", system-ui, sans-serif';

const fontCss = `@font-face{font-family:"Bree Serif";src:url(${staticFile('v2/BreeSerif-Regular.woff2')}) format("woff2");}
@font-face{font-family:"DM Sans";src:url(${staticFile('assets/DM-Sans.woff2')}) format("woff2");font-weight:100 1000;}`;

const useLocal = (from: number) => useCurrentFrame() - from;
const pop = (frame: number, damping = 13, stiffness = 180) => spring({frame, fps: FPS2, config: {damping, stiffness}});

function Big({children, from, size = 190, color = ink, delay = 0}: {children: React.ReactNode; from: number; size?: number; color?: string; delay?: number}) {
  const p = pop(useLocal(from) - delay);
  return <div style={{fontFamily: serif, fontSize: size, color, lineHeight: 1.02, letterSpacing: '-0.02em', opacity: p, transform: `translateY(${(1 - p) * 70}px)`, filter: `blur(${(1 - p) * 14}px)`}}>{children}</div>;
}

function Beat({from, to, bg = paper, children, align = 'center'}: {from: number; to: number; bg?: string; children: React.ReactNode; align?: 'center' | 'flex-start'}) {
  const frame = useCurrentFrame();
  if (frame < from || frame >= to) return null;
  return <AbsoluteFill style={{background: bg, alignItems: 'center', justifyContent: align, flexDirection: 'column', gap: 20, textAlign: 'center'}}>{children}</AbsoluteFill>;
}

// The hook: a reply being typed the slow way, with hesitation and a backspace.
const HOOK = 'hi marcus, sorry for the slow reply. just wanted to let you know the leas';
function Typing({from, to, text, speed = 1}: {from: number; to: number; text: string; speed?: number}) {
  const l = useLocal(from);
  const frame = useCurrentFrame();
  if (frame < from || frame >= to) return null;
  // ~9 chars/sec with a pause and a three-character backspace in the middle, the way people type.
  const raw = Math.max(0, l * speed * 0.32);
  const n = raw < 28 ? raw : raw < 34 ? 28 : raw < 37 ? 28 - (raw - 34) : 25 + (raw - 37);
  const shown = text.slice(0, Math.floor(Math.min(n, text.length)));
  const blink = Math.floor(frame / 8) % 2 === 0;
  const p = pop(l, 16);
  return <AbsoluteFill style={{background: paper, alignItems: 'center', justifyContent: 'center'}}>
    <div style={{width: 1240, borderRadius: 40, background: '#fff', boxShadow: '0 40px 120px rgba(32,42,46,.16), 0 0 0 1px rgba(32,42,46,.06)', padding: '46px 56px 40px', transform: `scale(${0.94 + 0.06 * p})`, opacity: p}}>
      <div style={{fontFamily: sans, fontSize: 30, color: mute, marginBottom: 20}}>Re: Oakland site, the lease</div>
      <div style={{fontFamily: sans, fontSize: 58, color: ink, minHeight: 150, lineHeight: 1.25}}>{shown}<span style={{opacity: blink ? 1 : 0, color: '#0a6fd6'}}>|</span></div>
      <div style={{display: 'flex', justifyContent: 'flex-end', marginTop: 16}}><div style={{background: '#0b57d0', color: '#fff', fontFamily: sans, fontSize: 30, fontWeight: 600, padding: '14px 36px', borderRadius: 999}}>Send</div></div>
    </div>
  </AbsoluteFill>;
}

function Dot({from}: {from: number}) {
  const l = useLocal(from);
  const p = pop(l, 9);
  const pulse = 1 + 0.12 * Math.sin(l / 4);
  return <div style={{width: 120, height: 120, borderRadius: 999, background: dot, transform: `scale(${p * pulse})`, boxShadow: `0 0 ${60 * pulse}px rgba(238,95,39,.55)`}} />;
}

type StageWindow = Window & {stage?: {ready?: Promise<boolean>; seekScene: (id: string, local: number, opts?: {playAfter?: number}) => void}};
// The live Gmail scene: the cue is heard word by word, then the reply writes itself in the compose box.
function Hero({from, to}: {from: number; to: number}) {
  const frame = useCurrentFrame();
  const iframe = useRef<HTMLIFrameElement>(null);
  const [loaded, setLoaded] = useState(false);
  const active = frame >= from && frame < to;
  const local = Math.max(0, (frame - from) / FPS2) * 1.45;
  const handle = useMemo(() => delayRender(`hero ${frame}`, {timeoutInMilliseconds: 60000}), [frame]);
  useEffect(() => {
    if (!loaded) return;
    let cancelled = false;
    (async () => {
      const win = iframe.current?.contentWindow as StageWindow | null;
      if (!win?.stage) throw new Error('stage API missing');
      await win.stage.ready;
      win.stage.seekScene('gmail', local, {playAfter: 0.3});
      await new Promise<void>(r => win.requestAnimationFrame(() => win.requestAnimationFrame(() => r())));
      if (!cancelled) continueRender(handle);
    })().catch(cancelRender);
    return () => {cancelled = true; continueRender(handle);};
  }, [loaded, local, handle]);
  const t = (frame - from) / FPS2;
  const zoom = interpolate(t, [0, 3.5, 9.5], [1.0, 1.08, 1.32], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic)});
  const tag = pop(frame - from - f(5.6), 12);
  return <AbsoluteFill style={{opacity: active ? 1 : 0}}>
    <AbsoluteFill style={{transform: `scale(${zoom})`, transformOrigin: '42% 78%'}}>
      <iframe ref={iframe} src={`${staticFile('stage/index.html')}?render=1`} onLoad={() => setLoaded(true)} style={{border: 0, width: '100%', height: '100%'}} />
    </AbsoluteFill>
    <div style={{position: 'absolute', left: 70, bottom: 90, fontFamily: serif, fontSize: 92, color: paper, background: ink, padding: '18px 44px 26px', borderRadius: 28, boxShadow: '0 30px 80px rgba(0,0,0,.3)', opacity: tag, transform: `translateY(${(1 - tag) * 40}px) scale(${0.9 + 0.1 * tag})`}}>written like you<span style={{color: dot}}>.</span></div>
    <div style={{position: 'absolute', right: 36, bottom: 30, fontFamily: sans, fontSize: 20, color: 'rgba(255,255,255,.85)', background: 'rgba(32,42,46,.5)', padding: '7px 14px', borderRadius: 999}}>product preview · synthetic data</div>
  </AbsoluteFill>;
}

function Window_({src, from, w, x = 0, y = 0, rot = -8, delay = 0}: {src: string; from: number; w: number; x?: number; y?: number; rot?: number; delay?: number}) {
  const l = useLocal(from) - delay;
  const p = pop(l, 15, 140);
  const drift = l / FPS2;
  return <Img src={staticFile(`v2/${src}.png`)} style={{position: 'absolute', width: w, left: `calc(50% + ${x}px)`, top: `calc(50% + ${y}px)`, borderRadius: 18, boxShadow: '0 50px 120px rgba(20,30,40,.35)', opacity: p,
    transform: `translate(-50%,-50%) perspective(2200px) rotateY(${rot * (1 - p) + rot * 0.4 - drift * 1.5}deg) rotateX(${6 * (1 - p) + 4}deg) translateY(${(1 - p) * 140}px) scale(${0.85 + 0.15 * p})`}} />;
}

function Only({from, to, src, label}: {from: number; to: number; src: string; label: string}) {
  return <Beat from={from} to={to} bg={`url(${staticFile('v2/intention-landscape-approved.webp')}) center/cover`}>
    <AbsoluteFill style={{background: 'rgba(249,250,247,.35)'}} />
    <Window_ src={src} from={from} w={1150} y={-70} />
    <div style={{position: 'absolute', bottom: 70, width: '100%'}}><Big from={from} size={130} delay={3}>{label}</Big></div>
  </Beat>;
}

function Voices({from}: {from: number}) {
  const items = [
    ['to a friend', 'running ten late. order me the usual, i’ll get this one'],
    ['to the team', 'Deck’s ready for 3. I moved pricing up front, and I’ll send it to the team right after lunch.'],
    ['to Marcus', 'Hi Marcus, Signed and sent back. The blue chairs arrive Thursday. Thank you for holding the place through the summer. Nadia'],
  ];
  return <div style={{display: 'flex', gap: 36, marginTop: 50}}>{items.map(([who, text], i) => {
    const p = pop(useLocal(from) - 6 - i * 5, 14);
    return <div key={who} style={{width: 500, minHeight: 300, background: '#fff', borderRadius: 30, padding: 36, textAlign: 'left', boxShadow: '0 30px 80px rgba(32,42,46,.12)', opacity: p, transform: `translateY(${(1 - p) * 80}px) rotate(${(i - 1) * 1.5 * (1 - p)}deg)`}}>
      <div style={{fontFamily: sans, fontSize: 26, color: dot, fontWeight: 700, marginBottom: 16}}>{who}</div>
      <div style={{fontFamily: sans, fontSize: 34, color: ink, lineHeight: 1.35}}>{text}</div>
    </div>;
  })}</div>;
}

const clock = (n: number) => `${Math.floor(n / 60)}:${String(Math.floor(n % 60)).padStart(2, '0')}`;
function Race({from}: {from: number}) {
  const l = useLocal(from);
  const t = l / FPS2;
  const typed = Math.min(129, t * 40), spoken = Math.min(36, t * 40);
  const row = (v: number, label: string, color: string) => <div style={{width: 1400, marginBottom: 54}}>
    <div style={{display: 'flex', justifyContent: 'space-between', fontFamily: sans, fontSize: 46, color: ink, marginBottom: 14}}><span>{label}</span><span style={{fontFamily: serif, fontSize: 64, fontVariantNumeric: 'tabular-nums'}}>{clock(v)}</span></div>
    <div style={{height: 34, borderRadius: 17, background: 'rgba(32,42,46,.08)'}}><div style={{height: '100%', width: `${(v / 129) * 100}%`, borderRadius: 17, background: color}} /></div>
  </div>;
  const win = pop(l - f(3.4), 10);
  return <AbsoluteFill style={{background: paper, alignItems: 'center', justifyContent: 'center'}}>
    <div style={{fontFamily: sans, fontSize: 30, letterSpacing: '.2em', color: mute, marginBottom: 60}}>THE SAME 86 WORDS</div>
    {row(spoken, 'said to intention', dot)}
    {row(typed, 'typed at 40 wpm', '#8a9aa3')}
    <div style={{fontFamily: serif, fontSize: 180, color: dot, opacity: win, transform: `scale(${0.5 + 0.5 * win})`, marginTop: 10}}>3.6× faster</div>
  </AbsoluteFill>;
}

export function Launch2() {
  const frame = useCurrentFrame();
  const land = `url(${staticFile('v2/intention-landscape-approved.webp')}) center/cover`;
  return <AbsoluteFill style={{background: paper}}>
    <style>{fontCss}</style>
    <Audio src={staticFile('v2/music.wav')} />
    <Hero from={f(9)} to={f(19)} />

    <Typing from={0} to={f(4)} text={HOOK} />
    <Beat from={f(4)} to={f(5.5)}><Big from={f(4)}>you write like this</Big></Beat>
    <Beat from={f(5.5)} to={f(7)}><Big from={f(5.5)} color={dot} size={240}>40 times a day</Big></Beat>
    <Beat from={f(7)} to={f(9)} bg={ink}><Dot from={f(7)} /><Big from={f(7)} color={paper} size={170} delay={6}>or just say it.</Big></Beat>

    <Only from={f(19)} to={f(20.5)} src="msg" label="in messages" />
    <Only from={f(20.5)} to={f(22)} src="slack" label="in slack" />
    <Only from={f(22)} to={f(23.5)} src="notes" label="in notes" />
    <Beat from={f(23.5)} to={f(26)} bg={land}>
      <AbsoluteFill style={{background: 'rgba(249,250,247,.3)'}} />
      <Window_ src="msg" from={f(23.5)} w={720} x={-430} y={-200} rot={10} />
      <Window_ src="slack" from={f(23.5)} w={760} x={420} y={-190} rot={-10} delay={3} />
      <Window_ src="gmail" from={f(23.5)} w={600} x={-430} y={230} rot={10} delay={6} />
      <Window_ src="notes" from={f(23.5)} w={680} x={430} y={230} rot={-10} delay={9} />
      <div style={{position: 'absolute', top: 420, width: '100%', zIndex: 2, display: 'flex', justifyContent: 'center'}}><div style={{background: paper, borderRadius: 40, padding: '6px 60px 22px', boxShadow: '0 30px 90px rgba(32,42,46,.25)'}}><Big from={f(23.5)} size={150} delay={12}>or all of them</Big></div></div>
    </Beat>
    <Beat from={f(26)} to={f(30)}><Big from={f(26)} size={150}>in <span style={{color: dot}}>your</span> voice</Big><Voices from={f(26)} /></Beat>
    {frame >= f(30) && frame < f(35) && <Race from={f(30)} />}
    <Beat from={f(35)} to={f(LAUNCH2_SECONDS)} bg={land}>
      <Img src={staticFile('assets/intention-wordmark.svg')} style={{height: 230, transform: `scale(${0.85 + 0.15 * pop(frame - f(35), 10)})`, opacity: pop(frame - f(35))}} />
      <Big from={f(35)} size={70} delay={12}>say it. it writes like you.</Big>
      <div style={{position: 'absolute', bottom: 60, fontFamily: sans, fontSize: 34, color: ink, opacity: pop(frame - f(37))}}>intention-gray.vercel.app</div>
    </Beat>
  </AbsoluteFill>;
}
