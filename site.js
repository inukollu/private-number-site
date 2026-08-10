const measurementId = 'G-6MSK833Q8L';
const storageKey = 'privatenumber.analytics-consent';
const subscriptionEndpoint = 'https://lists.inukollu.in/api/public/subscription';
const earlyAccessListId = '80a9ce90-163e-4887-b26c-758fedefc82a';
const subscribedEmailsKey = 'privatenumber.subscribed-emails';

function enableSectionMotion() {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  const revealGroups = [
    ...document.querySelectorAll('main > section'),
    ...document.querySelectorAll('.steps article, .privacy-grid article, .price-grid article, .faq details'),
  ];

  document.documentElement.classList.add('motion-ready');
  revealGroups.forEach((element, index) => {
    element.classList.add('reveal');
    element.style.setProperty('--reveal-delay', `${Math.min(index % 4, 3) * 70}ms`);
  });

  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    });
  }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

  revealGroups.forEach((element) => observer.observe(element));
}

enableSectionMotion();

function enableIdleSectionTour() {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  const sections = [...document.querySelectorAll('main > section')];
  const heroVisual = document.querySelector('.hero-visual');
  const firstDelay = 10000;
  const stepDelay = 7000;
  let timer;
  let stopped = false;
  let scenarioIndex = 0;
  const phoneScenarios = [
    {
      avatar: 'AR',
      name: 'Ananya Rao',
      type: 'New caller',
      summary: 'Calling about the design consultation you requested. Available tomorrow afternoon.',
      classification: 'Relevant request',
      primaryTag: 'Purpose identified',
      secondaryTag: 'Low risk',
      status: 'Caller connected · 00:24',
      outcome: 'Assistant connected the caller to you',
      decision: 'connect',
    },
    {
      avatar: 'YB',
      name: 'Your Bank',
      type: 'Promotional call',
      summary: 'Calling with a pre-approved personal loan offer. No action is required.',
      classification: 'Loan promotion',
      primaryTag: 'Promotion',
      secondaryTag: 'Not urgent',
      status: 'Call declined · 00:12',
      outcome: 'Declined by assistant · Caller not connected to you',
      decision: 'decline',
    },
  ];

  const stop = () => {
    stopped = true;
    window.clearTimeout(timer);
    heroVisual?.classList.remove('is-idle-pulsing');
    heroVisual?.classList.remove('decision--connect', 'decision--decline');
  };

  const schedule = (delay) => {
    timer = window.setTimeout(advance, delay);
  };

  const pulsePhone = () => {
    if (stopped) return;
    const scenario = phoneScenarios[scenarioIndex];
    heroVisual.querySelector('[data-call-avatar]').textContent = scenario.avatar;
    heroVisual.querySelector('[data-call-name]').textContent = scenario.name;
    heroVisual.querySelector('[data-call-type]').textContent = scenario.type;
    heroVisual.querySelector('[data-call-summary]').textContent = scenario.summary;
    heroVisual.querySelector('[data-call-classification]').textContent = scenario.classification;
    heroVisual.querySelector('[data-call-tag-primary]').textContent = scenario.primaryTag;
    heroVisual.querySelector('[data-call-tag-secondary]').textContent = scenario.secondaryTag;
    heroVisual.querySelector('[data-call-status]').textContent = scenario.status;
    heroVisual.querySelector('[data-call-outcome]').textContent = scenario.outcome;
    heroVisual?.classList.remove('decision--connect', 'decision--decline');
    heroVisual?.classList.add(`decision--${scenario.decision}`);
    heroVisual?.classList.add('is-idle-pulsing');
    scenarioIndex = (scenarioIndex + 1) % phoneScenarios.length;
    timer = window.setTimeout(() => {
      heroVisual?.classList.remove('is-idle-pulsing');
      timer = window.setTimeout(pulsePhone, 5200);
    }, 1800);
  };

  const advance = () => {
    if (stopped || document.hidden) {
      if (!stopped) schedule(stepDelay);
      return;
    }

    const currentPosition = window.scrollY + window.innerHeight * 0.35;
    const next = sections.find((section) => section.offsetTop > currentPosition);
    if (!next) {
      sections[0]?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      timer = window.setTimeout(pulsePhone, 1400);
      return;
    }

    next.scrollIntoView({ behavior: 'smooth', block: 'start' });
    schedule(stepDelay);
  };

  ['pointerdown', 'keydown', 'wheel', 'touchstart'].forEach((eventName) =>
    window.addEventListener(eventName, stop, { once: true, passive: true }));
  document.addEventListener('focusin', stop, { once: true });
  schedule(firstDelay);
}

function readConsent() {
  try {
    const value = localStorage.getItem(storageKey);
    return value === 'granted' || value === 'denied' ? value : null;
  } catch {
    return null;
  }
}

function storeConsent(value) {
  try {
    localStorage.setItem(storageKey, value);
  } catch {
    // Keep the in-memory choice when browser storage is unavailable.
  }
}

function setAnalyticsDisabled(disabled) {
  window[`ga-disable-${measurementId}`] = disabled;
}

function loadAnalytics() {
  if (document.getElementById('google-analytics')) return;

  window.dataLayer = window.dataLayer || [];
  window.gtag = (...args) => window.dataLayer.push(args);
  window.gtag('js', new Date());
  window.gtag('config', measurementId, {
    send_page_view: true,
    cookie_flags: 'SameSite=None;Secure',
  });

  const script = document.createElement('script');
  script.id = 'google-analytics';
  script.async = true;
  script.src = `https://www.googletagmanager.com/gtag/js?id=${measurementId}`;
  document.head.appendChild(script);
}

function track(eventName) {
  if (readConsent() === 'granted' && window.gtag) {
    window.gtag('event', eventName);
  }
}

const banner = document.querySelector('[data-consent-banner]');

function showConsent(show) {
  banner.hidden = !show;
}

if (readConsent() === 'granted') loadAnalytics();
showConsent(readConsent() === null);

document.querySelector('[data-consent-grant]').addEventListener('click', () => {
  storeConsent('granted');
  setAnalyticsDisabled(false);
  loadAnalytics();
  track('analytics_consent_granted');
  showConsent(false);
});

document.querySelector('[data-consent-deny]').addEventListener('click', () => {
  storeConsent('denied');
  setAnalyticsDisabled(true);
  showConsent(false);
});

document.querySelector('[data-consent-reset]').addEventListener('click', () => {
  showConsent(true);
});

document.addEventListener('click', (event) => {
  const action = event.target.closest?.('[data-analytics-event]')?.dataset.analyticsEvent;
  if (action) track(action);
});

const waitlistForm = document.querySelector('[data-waitlist-form]');
const waitlistEmail = waitlistForm.querySelector('[name="email"]');
const waitlistSubmit = document.querySelector('[data-waitlist-submit]');
const waitlistStatus = document.querySelector('[data-waitlist-status]');

function setWaitlistStatus(message, state) {
  waitlistStatus.textContent = message;
  waitlistStatus.dataset.state = state;
  waitlistStatus.hidden = false;
}

function readSubscribedEmails() {
  try {
    const emails = JSON.parse(localStorage.getItem(subscribedEmailsKey) ?? '[]');
    return Array.isArray(emails) ? emails : [];
  } catch {
    return [];
  }
}

function rememberSubscribedEmail(email) {
  try {
    const emails = new Set(readSubscribedEmails());
    emails.add(email);
    localStorage.setItem(subscribedEmailsKey, JSON.stringify([...emails]));
  } catch {
    // A successful subscription should not be treated as failed if storage is unavailable.
  }
}

function markWaitlistSubmitted() {
  waitlistEmail.disabled = true;
  waitlistSubmit.disabled = true;
  waitlistSubmit.textContent = 'Check your inbox';
  setWaitlistStatus('Check your inbox to confirm your place on the early-access list.', 'success');
}

waitlistForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!waitlistForm.reportValidity()) return;

  const email = new FormData(waitlistForm).get('email')?.toString().trim().toLowerCase();
  if (!email) return;

  if (readSubscribedEmails().includes(email)) {
    waitlistForm.reset();
    markWaitlistSubmitted();
    return;
  }

  waitlistSubmit.disabled = true;
  waitlistSubmit.textContent = 'Joining…';
  waitlistStatus.hidden = true;

  try {
    const body = new URLSearchParams({ email, l: earlyAccessListId });
    const response = await fetch(subscriptionEndpoint, {
      method: 'POST',
      headers: { Accept: 'application/json' },
      body,
    });

    if (!response.ok) throw new Error(`Subscription failed with ${response.status}`);

    waitlistForm.reset();
    rememberSubscribedEmail(email);
    markWaitlistSubmitted();
    track('join_waitlist');
  } catch {
    setWaitlistStatus('We could not add you right now. Please try again in a moment.', 'error');
    waitlistSubmit.disabled = false;
    waitlistSubmit.textContent = 'Join the waitlist';
  }
});

enableIdleSectionTour();

const testimonialSection = document.querySelector('[data-testimonials]');
const testimonialList = document.querySelector('[data-testimonial-list]');
const testimonialPreview = ['localhost', '127.0.0.1'].includes(location.hostname) && new URLSearchParams(location.search).has('testimonialPreview');
const testimonialRequest = testimonialPreview
  ? Promise.resolve([{ text: 'PrivateNumber lets me handle marketplace calls without exposing the number my family uses.', name: 'Ananya Rao', location: 'Bengaluru, India' }, { text: 'Unknown callers are screened first, so I can decide what deserves my attention.', name: 'PrivateNumber customer' }, { text: 'I can keep my personal number private while still hearing from the people who matter.', name: 'PrivateNumber customer', location: 'Pune, India' }])
  : fetch('https://app.privatenumber.in/api/v1/testimonials/public', { headers: { Accept: 'application/json' } }).then((response) => response.ok ? response.json() : []);
testimonialRequest
  .then((items) => {
    if (!Array.isArray(items) || items.length === 0) return;
    for (const item of items) {
      const article = document.createElement('article');
      const quote = document.createElement('blockquote');
      const name = document.createElement('p');
      const photo = document.createElement('img');
      photo.src = item.photoUrl ? new URL(item.photoUrl, 'https://app.privatenumber.in').toString() : '/assets/testimonial-neutral.svg';
      photo.alt = '';
      article.append(photo);
      quote.textContent = item.text;
      name.textContent = item.location ? `${item.name} · ${item.location}` : item.name;
      article.append(quote, name);
      testimonialList.append(article);
    }
    testimonialSection.hidden = false;
  })
  .catch(() => {});
